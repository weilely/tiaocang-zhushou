import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/dca.dart';
import 'market_api.dart';
import 'models.dart';
import 'nav_source.dart';

/// 定投补记要用的历史价格源
///
/// | 标的 | 来源 | 说明 |
/// | --- | --- | --- |
/// | 场外基金 | `pingzhongdata/{code}.js`（**一次给全历史**） | 拿不到再退回 `f10/lsjz` |
/// | ETF / LOF | 同上 | 与交易所收盘价差异极小（NAV 4.5794 vs 收盘 4.579） |
/// | 股票 | `push2his` 日 K 线 | 整段一次给完；该域名目前被限流，取不到就跳过该期 |
///
/// ⚠️ **不要只用 `f10/lsjz`**（2026-09-30 的教训）：它的 `pageSize` **硬上限是 20**
/// （写 `pageSize=200` 也只回 20 条），而且回的是**窗口里最新的 20 条**。
/// 用户「想通过定投生成历史记录，结果不管用」就是这么来的：计划起始日在两年前时，
/// 最早的待补期数全落在 20 条之外 → 一条价都取不到 → 一期也生成不出来。
/// 现在：pingzhongdata 一次拿全；真拿不到才退回 **翻页** 的 lsjz（每页 20，翻到覆盖住 `from`）。
class DcaPriceSource {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  DcaPriceSource([http.Client? client]) : _client = client ?? http.Client();

  /// 取全量历史用（和「历史净值」页同一条通道，别另造一份解析）
  late final NavSource _nav = NavSource(_client);

  void dispose() => _client.close();

  Future<String> _get(String url, {Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final res = await _client.get(Uri.parse(url), headers: {
        'User-Agent': _ua,
        // lsjz 没有这个 Referer 会返回 ErrCode -999
        'Referer': 'https://fundf10.eastmoney.com/',
      }).timeout(timeout);
      if (res.statusCode != 200) {
        throw MarketException('HTTP ${res.statusCode}');
      }
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } on MarketException {
      rethrow;
    } catch (e) {
      throw MarketException('网络错误：$e');
    }
  }

  /// 按标的分流取历史价格；返回 `yyyy-MM-dd → 价格`
  Future<Map<String, double>> historyFor(
    Asset asset,
    DateTime from,
    DateTime to,
  ) async {
    final errors = <String>[];

    if (asset.kind == AssetKind.fund) {
      try {
        return await fundHistory(asset.code, from, to, asset: asset);
      } on MarketException catch (e) {
        errors.add(e.message);
      }
    } else if (asset.kind == AssetKind.etf) {
      // ETF/LOF 先走基金净值（已实测可用），拿不到再试交易所 K 线
      try {
        final m = await fundHistory(asset.code, from, to, asset: asset);
        if (m.isNotEmpty) return m;
      } on MarketException catch (e) {
        errors.add(e.message);
      }
      try {
        return await stockHistory(asset, from, to);
      } on MarketException catch (e) {
        errors.add(e.message);
      }
    } else {
      try {
        return await stockHistory(asset, from, to);
      } on MarketException catch (e) {
        errors.add(e.message);
      }
    }

    if (errors.isNotEmpty) throw MarketException(errors.join('；'));
    return const {};
  }

  /// 取 [day] 前后一段窗口的「日期 → 价格」，供交易表单按交易日查净值用
  ///
  /// 向前 [backDays] 天、向后 [forwardDays] 天（但**不越过今天**：未来不可能有
  /// 净值）。窗口是有界的，所以调用方拿到的兜底值最多比所选日期早 [backDays] 天。
  Future<Map<String, double>> pricesAround(
    Asset asset,
    DateTime day, {
    DateTime? today,
    int backDays = 20,
    int forwardDays = 12,
  }) async {
    final d = dayOnly(day);
    final t = dayOnly(today ?? DateTime.now());
    final to = d.add(Duration(days: forwardDays)).isAfter(t)
        ? t
        : d.add(Duration(days: forwardDays));
    final from = d.subtract(Duration(days: backDays));
    if (to.isBefore(from)) return const {};
    return historyFor(asset, from, to);
  }

  /// 场外基金 / 场内基金的历史**单位净值**
  ///
  /// 两级：
  /// 1. `pingzhongdata/{code}.js`（[NavSource.fullHistory]，**一次给全历史**）——
  ///    走的就是「历史净值」页那条通道，解析只此一份；
  /// 2. 拿不到才退回 `f10/lsjz`，并在 [lsjzPaged] 里**翻页**（每页硬上限 20 条）。
  Future<Map<String, double>> fundHistory(
    String code,
    DateTime from,
    DateTime to, {
    Asset? asset,
  }) async {
    final lo = dayKey(from);
    final hi = dayKey(to);
    if (asset != null) {
      try {
        final pts = await _nav.fullHistory(asset);
        final m = <String, double>{
          for (final p in pts)
            if (p.nav > 0 && p.date.compareTo(lo) >= 0 && p.date.compareTo(hi) <= 0)
              p.date: p.nav,
        };
        if (m.isNotEmpty) return m;
      } catch (_) {
        // 掉到 lsjz
      }
    }
    return lsjzPaged(code, from, to);
  }

  /// `f10/lsjz` **翻页**取历史净值（每页 20 条是接口硬上限）
  ///
  /// 停的条件：某一页不满 20 条（到底了），或已经覆盖到窗口起点 [from]。
  /// 页数上限 60（≈1200 个交易日 ≈ 5 年）—— 够补很旧的历史，也不会无限翻。
  Future<Map<String, double>> lsjzPaged(
    String code,
    DateTime from,
    DateTime to, {
    int maxPages = 60,
  }) async {
    final lo = dayKey(from);
    final out = <String, double>{};

    for (var page = 1; page <= maxPages; page++) {
      final url = 'https://api.fund.eastmoney.com/f10/lsjz'
          '?fundCode=$code&pageIndex=$page&pageSize=20'
          '&startDate=$lo&endDate=${dayKey(to)}';

      final body = await _get(url);
      final dynamic json = jsonDecode(body);
      if (json is! Map) throw MarketException('净值历史返回格式异常');

      final err = (json['ErrCode'] as num?)?.toInt() ?? 0;
      if (err != 0) {
        // 第一页就报错才算错；翻到后面报错（限流）就当已拿到多少算多少
        if (page == 1) {
          throw MarketException('净值历史接口返回 ErrCode=$err（代码 $code）');
        }
        break;
      }

      final data = json['Data'];
      final list = (data is Map) ? data['LSJZList'] : null;
      final rows = list is List ? list : const [];
      var oldest = '';
      for (final raw in rows) {
        if (raw is! Map) continue;
        final d = (raw['FSRQ'] ?? '').toString();
        final nav = double.tryParse((raw['DWJZ'] ?? '').toString());
        if (d.length >= 10 && nav != null && nav > 0) {
          final key = d.substring(0, 10);
          out[key] = nav;
          if (oldest.isEmpty || key.compareTo(oldest) < 0) oldest = key;
        }
      }

      if (rows.length < 20) break; // 最后一页
      if (oldest.isNotEmpty && oldest.compareTo(lo) <= 0) break; // 已覆盖到窗口起点
    }
    // 空表不是错误：可能是股票代码（该接口对股票返回空列表），交给调用方决定
    return out;
  }

  /// 旧签名（不认识标的、只能走 lsjz）——保留给只按代码调用的地方
  Future<Map<String, double>> fundHistoryByCode(
    String code,
    DateTime from,
    DateTime to,
  ) =>
      lsjzPaged(code, from, to);

  /// 股票 / ETF 的日 K 线收盘价
  Future<Map<String, double>> stockHistory(
    Asset asset,
    DateTime from,
    DateTime to,
  ) async {
    final secid = MarketService.secidFor(asset);
    if (secid == null) throw MarketException('无法确定 ${asset.code} 的市场');

    final beg = dayKey(from).replaceAll('-', '');
    final end = dayKey(to).replaceAll('-', '');
    final url = 'https://push2his.eastmoney.com/api/qt/stock/kline/get'
        '?secid=$secid&fields1=f1&fields2=f51,f53&klt=101&fqt=0'
        '&beg=$beg&end=$end';

    final body = await _get(url, timeout: const Duration(seconds: 12));
    final dynamic json = jsonDecode(body);
    if (json is! Map) throw MarketException('K 线返回格式异常');

    final data = json['data'];
    final klines = (data is Map) ? data['klines'] : null;
    final out = <String, double>{};
    if (klines is List) {
      for (final line in klines) {
        final parts = line.toString().split(',');
        if (parts.length < 2) continue;
        final d = parts[0].trim();
        final close = double.tryParse(parts[1].trim());
        if (d.length >= 10 && close != null && close > 0) {
          out[d.substring(0, 10)] = close;
        }
      }
    }
    if (out.isEmpty) throw MarketException('K 线为空（可能被限流）');
    return out;
  }
}
