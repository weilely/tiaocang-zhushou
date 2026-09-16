import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/dca.dart';
import 'market_api.dart';
import 'models.dart';

/// 定投补记要用的历史价格源
///
/// | 标的 | 来源 | 说明 |
/// | --- | --- | --- |
/// | 场外基金 | `f10/lsjz` 历史净值 | **必须带 Referer**，否则 ErrCode = -999 |
/// | ETF / LOF | 同上（该接口也覆盖场内基金） | 与交易所收盘价差异极小（NAV 4.5794 vs 收盘 4.579） |
/// | 股票 | `push2his` 日 K 线 | 该域名目前被限流，取不到就跳过该期 |
class DcaPriceSource {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  DcaPriceSource([http.Client? client]) : _client = client ?? http.Client();

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
        return await fundHistory(asset.code, from, to);
      } on MarketException catch (e) {
        errors.add(e.message);
      }
    } else if (asset.kind == AssetKind.etf) {
      // ETF/LOF 先走基金净值（已实测可用），拿不到再试交易所 K 线
      try {
        final m = await fundHistory(asset.code, from, to);
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

  /// 场外基金 / 场内基金的历史单位净值
  Future<Map<String, double>> fundHistory(
    String code,
    DateTime from,
    DateTime to,
  ) async {
    final url = 'https://api.fund.eastmoney.com/f10/lsjz'
        '?fundCode=$code&pageIndex=1&pageSize=200'
        '&startDate=${dayKey(from)}&endDate=${dayKey(to)}';

    final body = await _get(url);
    final dynamic json = jsonDecode(body);
    if (json is! Map) throw MarketException('净值历史返回格式异常');

    final err = (json['ErrCode'] as num?)?.toInt() ?? 0;
    if (err != 0) {
      throw MarketException('净值历史接口返回 ErrCode=$err（代码 $code）');
    }

    final data = json['Data'];
    final list = (data is Map) ? data['LSJZList'] : null;
    final out = <String, double>{};
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final d = (raw['FSRQ'] ?? '').toString();
        final nav = double.tryParse((raw['DWJZ'] ?? '').toString());
        if (d.length >= 10 && nav != null && nav > 0) {
          out[d.substring(0, 10)] = nav;
        }
      }
    }
    // 空表不是错误：可能是股票代码（该接口对股票返回空列表），交给调用方决定
    return out;
  }

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
