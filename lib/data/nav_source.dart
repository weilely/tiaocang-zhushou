import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/format.dart';
import 'market_api.dart';
import 'models.dart';
import 'nav_models.dart';

/// 历史净值与大盘指数的数据源
///
/// | 用途 | 接口 | 备注 |
/// | --- | --- | --- |
/// | 基金/ETF 全量历史 | `pingzhongdata/{code}.js` | **一次拿全部**；含净值和累计净值两条序列 |
/// | 增量 | `f10/lsjz` | **pageSize 硬上限 20**；**必须带 Referer**，否则 ErrCode=-999 |
/// | 股票历史 | 新浪 `CN_MarketDataService.getKLineData` | push2his 被限流时的替代 |
/// | 大盘指数 | `hq.sinajs.cn/list=s_xxx` | 精简格式，约 150 字节 |
class NavSource {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  NavSource([http.Client? client]) : _client = client ?? http.Client();

  void dispose() => _client.close();

  Future<http.Response> _raw(String url,
      {String referer = 'https://fund.eastmoney.com/',
      Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await _client.get(Uri.parse(url), headers: {
        'User-Agent': _ua,
        'Referer': referer,
      }).timeout(timeout);
    } on MarketException {
      rethrow;
    } catch (e) {
      throw MarketException('网络错误：$e');
    }
  }

  Future<String> _text(String url,
      {String referer = 'https://fund.eastmoney.com/',
      Duration timeout = const Duration(seconds: 30)}) async {
    final res = await _raw(url, referer: referer, timeout: timeout);
    if (res.statusCode != 200) throw MarketException('HTTP ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  // ---------------- 全量历史 ----------------

  /// 一次拿全量历史。基金/ETF 走 pingzhongdata，其余（股票、指数）走新浪日K。
  ///
  /// [datalen] 只对指数/股票有效，且新浪**有上限**：实测 `1500` 可用
  /// （回溯约 6 年），`2000` 直接返回空。因此指数基准传 1500，其余保持默认 1000。
  Future<List<NavPoint>> fullHistory(Asset asset, {int datalen = 1000}) async {
    if (asset.kind == AssetKind.fund || asset.kind == AssetKind.etf) {
      final pts = await _pingzhongdata(asset.code);
      if (pts.isNotEmpty) return pts;
    }
    return sinaDaily(asset, datalen: datalen);
  }

  /// `pingzhongdata/{code}.js` —— 净值与累计净值两条序列，按时间戳对齐
  Future<List<NavPoint>> _pingzhongdata(String code) async {
    final text = await _text('https://fund.eastmoney.com/pingzhongdata/$code.js');

    final netMatch =
        RegExp(r'Data_netWorthTrend\s*=\s*(\[.*?\]);').firstMatch(text);
    if (netMatch == null) return const [];

    final acMatch =
        RegExp(r'Data_ACWorthTrend\s*=\s*(\[.*?\]);').firstMatch(text);

    // 累计净值：时间戳 → 值
    final accByTs = <int, double>{};
    if (acMatch != null) {
      final acList = jsonDecode(acMatch.group(1)!);
      if (acList is List) {
        for (final item in acList) {
          if (item is List && item.length >= 2) {
            final ts = (item[0] as num).toInt();
            final v = (item[1] as num).toDouble();
            if (v > 0) accByTs[ts] = v;
          }
        }
      }
    }

    final netList = jsonDecode(netMatch.group(1)!);
    if (netList is! List) return const [];

    final out = <NavPoint>[];
    for (final raw in netList) {
      if (raw is! Map) continue;
      final ts = (raw['x'] as num?)?.toInt();
      final nav = (raw['y'] as num?)?.toDouble();
      if (ts == null || nav == null || nav <= 0) continue;

      // x 是「净值日 00:00（UTC+8）」的时间戳，必须固定按 UTC+8 折算成日期：
      // 按设备本地时区解释的话，手机时区在 UTC+8 以西时整条序列会提前一天
      // （日历图上就是「周五空着、周日有收益」）。
      out.add(NavPoint(
        code: code,
        date: cnDayFromEpochMillis(ts),
        nav: nav,
        accNav: accByTs[ts] ?? nav,
        changePct: (raw['equityReturn'] as num?)?.toDouble() ?? 0,
        dividend: (raw['unitMoney'] ?? '').toString().trim(),
      ));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// 新浪日K（股票/ETF 兜底）
  Future<List<NavPoint>> sinaDaily(Asset asset, {int datalen = 1000}) async {
    final sym = _sinaSymbol(asset);
    if (sym == null) throw MarketException('无法确定 ${asset.code} 的市场');

    final text = await _text(
      'https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData'
      '?symbol=$sym&scale=240&ma=no&datalen=$datalen',
      referer: 'https://finance.sina.com.cn/',
    );

    final dynamic json = jsonDecode(text);
    if (json is! List) throw MarketException('日K返回格式异常');

    final out = <NavPoint>[];
    for (final raw in json) {
      if (raw is! Map) continue;
      final day = (raw['day'] ?? '').toString();
      final close = double.tryParse((raw['close'] ?? '').toString());
      if (day.length < 10 || close == null || close <= 0) continue;

      out.add(NavPoint(
        code: asset.code,
        date: day.substring(0, 10),
        nav: close,
        accNav: close,
        // 涨跌幅先留空，排完序再按**前一条收盘价**补 —— 这个接口不给昨收，
        // 拿 open 当基准算出来的是"开盘到收盘"，不是当日涨跌幅（旧版就是错的）
        changePct: 0,
      ));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return [
      for (var i = 0; i < out.length; i++)
        i == 0
            ? out[i]
            : NavPoint(
                code: out[i].code,
                date: out[i].date,
                nav: out[i].nav,
                accNav: out[i].accNav,
                changePct: out[i - 1].nav > 0
                    ? (out[i].nav / out[i - 1].nav - 1) * 100
                    : 0,
              ),
    ];
  }

  // ---------------- 增量 ----------------

  /// 增量：从最新往回翻，**遇到 [stopDate]（本地已有日期）即停**
  ///
  /// 按标的类型分流：
  /// - **基金 / ETF**：走 `lsjz`；它的 pageSize 上限是 20，所以最多翻 [maxPages] 页
  /// - **股票 / 指数**：走新浪日K 取近 [sinaDays] 个交易日。`nav_history` 有
  ///   `PRIMARY KEY (code, date)` 且写入用 replace，重复抓取天然幂等，不用自己判重
  ///
  /// 之前这里对**所有**标的都调 `lsjz`，而 `lsjz` 只认基金代码——纯股票一旦入库
  /// 就再也无法增量更新（ETF 侥幸能用）。这个分流同时修掉了那个缺陷，
  /// 也是指数基准能持续更新的前提。
  Future<List<NavPoint>> recentHistory(
    Asset asset, {
    String? stopDate,
    int maxPages = 5,
    int sinaDays = 60,
  }) async {
    if (asset.kind != AssetKind.fund && asset.kind != AssetKind.etf) {
      return sinaDaily(asset, datalen: sinaDays);
    }
    return _lsjzRecent(asset.code, stopDate: stopDate, maxPages: maxPages);
  }

  /// 基金专用增量：天天基金 `lsjz`
  Future<List<NavPoint>> _lsjzRecent(
    String code, {
    String? stopDate,
    int maxPages = 5,
  }) async {
    final out = <NavPoint>[];
    for (var page = 1; page <= maxPages; page++) {
      final text = await _text(
        'https://api.fund.eastmoney.com/f10/lsjz'
        '?fundCode=$code&pageIndex=$page&pageSize=20',
        referer: 'https://fundf10.eastmoney.com/',
        timeout: const Duration(seconds: 20),
      );

      final dynamic json = jsonDecode(text);
      if (json is! Map) throw MarketException('净值返回格式异常');
      final err = (json['ErrCode'] as num?)?.toInt() ?? 0;
      if (err != 0) {
        throw MarketException('净值接口 ErrCode=$err（代码 $code）');
      }

      final data = json['Data'];
      final list = (data is Map) ? data['LSJZList'] : null;
      if (list is! List || list.isEmpty) break;

      var reachedKnown = false;
      for (final raw in list) {
        if (raw is! Map) continue;
        final d = (raw['FSRQ'] ?? '').toString();
        final nav = double.tryParse((raw['DWJZ'] ?? '').toString());
        if (d.length < 10 || nav == null || nav <= 0) continue;

        final day = d.substring(0, 10);
        if (stopDate != null && day.compareTo(stopDate) <= 0) {
          reachedKnown = true;
          break;
        }
        out.add(NavPoint(
          code: code,
          date: day,
          nav: nav,
          accNav: double.tryParse((raw['LJJZ'] ?? '').toString()) ?? nav,
          changePct: double.tryParse((raw['JZZZL'] ?? '').toString()) ?? 0,
          dividend: (raw['FHFCZ'] ?? '').toString().trim(),
        ));
      }
      if (reachedKnown) break;
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // ---------------- 大盘指数 ----------------

  /// 上金所黄金的**新浪备用行情**（东财 `push2` 整站 502 时用）
  ///
  /// 实测背景：2026-09-21/22 东财 `push2.eastmoney.com` 两次整站 502（连最普通的
  /// 指数都取不到），跑马灯全是占位符；而新浪一直可用。
  /// 代码映射：`em:118.AU9999` → `gds_AU9999`（上金所 Au99.99）。
  /// **腾讯没有上金所黄金**（只返回 `v_pv_none_match`），所以只能走新浪。
  ///
  /// 商品格式的字段与股票不同：`0=现价 7=昨收`（`gds_AU9999` 实测
  /// `938.00,...,938.09` → 与东财的 -0.01% 完全一致），涨跌幅要自己算。
  Future<Map<String, Quote>> sinaCommodityQuotes(List<String> codes) async {
    final sinaToCode = <String, String>{};
    for (final c in codes) {
      final sid = c.startsWith('em:') ? c.substring(3) : c;
      final sina = switch (sid) {
        '118.AU9999' => 'gds_AU9999',
        '118.AUTD' => 'gds_AUTD',
        _ => null,
      };
      if (sina != null) sinaToCode[sina] = c;
    }
    if (sinaToCode.isEmpty) return const {};

    final text = await _text(
      'https://hq.sinajs.cn/list=${sinaToCode.keys.join(',')}',
      referer: 'https://finance.sina.com.cn/',
      timeout: const Duration(seconds: 12),
    );

    final out = <String, Quote>{};
    final re = RegExp(r'hq_str_(\w+)="([^"]*)"');
    for (final m in re.allMatches(text)) {
      final sina = m.group(1)!;
      final code = sinaToCode[sina];
      if (code == null) continue;
      final parts = m.group(2)!.split(',');
      if (parts.length < 8) continue;
      final price = double.tryParse(parts[0]) ?? 0;
      final prevClose = double.tryParse(parts[7]) ?? 0;
      if (price <= 0) continue;
      final pct = prevClose > 0 ? (price - prevClose) / prevClose * 100 : 0.0;
      out[code] = Quote(
        code: code,
        kind: AssetKind.etf,
        name: '',
        price: price,
        prevClose: prevClose,
        changePct: pct,
        priceType: 'price',
        updatedAt: DateTime.now(),
      );
    }
    return out;
  }

  /// 新浪精简指数行情：`名称,现价,涨跌额,涨跌%,成交量,成交额`
  ///
  /// 指数、ETF、股票都走这个接口（`s_sh510300` 一样有价格和涨幅）；
  /// 代码会先规范化补上 `sh` / `sz` / `bj` 前缀，用户直接填 `510300` 也能用。
  Future<List<IndexQuote>> indexQuotes(List<String> codes) async {
    if (codes.isEmpty) return const [];
    final normalized = [for (final c in codes) normalizeIndexCode(c)];
    final text = await _text(
      'https://hq.sinajs.cn/list=${normalized.map((c) => 's_$c').join(',')}',
      referer: 'https://finance.sina.com.cn/',
      timeout: const Duration(seconds: 12),
    );

    final out = <IndexQuote>[];
    // 港美股（hk / gb_）是另一种前缀，这里只认 sh/sz/bj + 6 位
    final re = RegExp(r'hq_str_s_([a-z]{2}\d{6})="([^"]*)"');
    for (final m in re.allMatches(text)) {
      final code = m.group(1)!;
      final parts = m.group(2)!.split(',');
      if (parts.length < 4) continue;
      final preset = MarketIndex.byCode(code);
      out.add(IndexQuote(
        code: code,
        // 名称一律取本地预设：该接口返回 GBK 编码，用 UTF-8 解会得到乱码，
        // 所以不让接口的文字参与显示（自定义指标的名字由池子提供）。
        name: preset?.name ?? code,
        price: double.tryParse(parts[1]) ?? 0,
        change: double.tryParse(parts[2]) ?? 0,
        changePct: double.tryParse(parts[3]) ?? 0,
      ));
    }
    // 保持请求顺序
    out.sort((a, b) =>
        normalized.indexOf(a.code).compareTo(normalized.indexOf(b.code)));
    return out;
  }

  static String? _sinaSymbol(Asset a) {
    final code = a.code.trim();
    // `MarketIndex.presets` 的代码本身就是带市场前缀的 8 位（如 `sh000300`），
    // 直接原样使用，这样预设指数无需任何映射就能当标的抓取，
    // 而且 8 位 key 与 6 位基金/股票代码在 nav_history 里不可能撞车。
    if (RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(code)) return code;
    if (code.length != 6) return null;
    if (a.market == 'SH') return 'sh$code';
    if (a.market == 'SZ') return 'sz$code';
    if (a.market == 'BJ') return 'bj$code';
    return MarketService.isShanghaiCode(code) ? 'sh$code' : 'sz$code';
  }
}
