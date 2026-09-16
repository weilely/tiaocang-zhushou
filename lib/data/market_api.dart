import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/format.dart';
import 'models.dart';
import 'nav_models.dart';

class MarketException implements Exception {
  final String message;
  MarketException(this.message);
  @override
  String toString() => message;
}

/// 行情数据源：东方财富公开接口
///
/// - 场外基金：基金净值 + 盘中估值（fundmobapi）
/// - 股票 / ETF：交易所实时行情（push2）
class MarketService {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 12; AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  static const String _ut = 'fa5fd1943c7b386f172d6893dbfba10b';
  static const String _searchToken = 'D43BF722C8E33BDC906FB84D85E326E8';

  final http.Client _client;
  MarketService([http.Client? client]) : _client = client ?? http.Client();

  void dispose() => _client.close();

  Future<String> _get(String url, {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final res = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Referer': 'https://fund.eastmoney.com/',
          'Accept': '*/*',
        },
      ).timeout(timeout);
      if (res.statusCode != 200) {
        throw MarketException('HTTP ${res.statusCode}');
      }
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } on MarketException {
      rethrow;
    } on TimeoutException {
      throw MarketException('请求超时，请检查网络连接');
    } catch (e) {
      throw MarketException('网络错误：$e');
    }
  }

  /// 交易所代码 -> 东财 secid（1=沪市, 0=深市）
  /// 北交所代码（920xxx / 8xxxxx）
  static bool isBeijingCode(String code) =>
      code.startsWith('920') || code.startsWith('8');

  /// 是否沪市（5/6 开头；9 开头里除北交所外按沪市处理）
  static bool isShanghaiCode(String code) {
    if (code.isEmpty) return false;
    final c = code[0];
    if (c == '5' || c == '6') return true;
    if (c == '9') return !isBeijingCode(code);
    return false;
  }

  /// 翻转 secid 的市场前缀：`0.x` ↔ `1.x`
  static String flipSecid(String secid) => secid.startsWith('1.')
      ? '0.${secid.substring(2)}'
      : '1.${secid.substring(2)}';

  /// 交易所代码 -> 东财 secid（1=沪市, 0=深市/北交所）
  ///
  /// 北交所的 secid 前缀东财未公开文档化，探测时又撞上 push2 限流，
  /// 所以这里给默认值，并由 [fetchExchangeQuotes] 在返回为空时自动翻前缀重试，
  /// 不把正确性押在猜测上。
  static String? secidFor(Asset a) {
    final code = a.code.trim();
    if (code.length != 6) return null;
    switch (a.market) {
      case 'SH':
        return '1.$code';
      case 'SZ':
      case 'BJ':
        return '0.$code';
    }
    return (isShanghaiCode(code) ? '1.' : '0.') + code;
  }

  static String marketFor(String code) {
    if (code.isEmpty) return '';
    if (isBeijingCode(code)) return 'BJ';
    return isShanghaiCode(code) ? 'SH' : 'SZ';
  }

  /// 拉取一批标的的最新行情；按标的类型自动分流
  Future<Map<String, Quote>> fetchAll(List<Asset> assets) async {
    final out = <String, Quote>{};
    final funds = assets.where((a) => a.kind == AssetKind.fund).toList();
    final exch = assets.where((a) => a.kind.isExchange).toList();
    final errors = <String>[];

    if (funds.isNotEmpty) {
      try {
        out.addAll(await fetchFundNavs(
          funds.map((e) => e.code).toList(),
          kinds: {for (final a in funds) a.code: a.kind},
        ));
      } on MarketException catch (e) {
        errors.add('基金净值: ${e.message}');
      }
    }
    if (exch.isNotEmpty) {
      try {
        out.addAll(await fetchExchangeQuotes(exch));
      } on MarketException catch (e) {
        errors.add('股票行情: ${e.message}');
      }

      // 交易所接口失败（例如被限流返回 502）时，ETF/LOF 退回基金接口：
      // 那个接口对场内基金同样会返回交易所现价 NEWPRICE，口径一致。
      final missingEtf = exch
          .where((a) => a.kind == AssetKind.etf && !out.containsKey(a.code))
          .toList();
      if (missingEtf.isNotEmpty) {
        try {
          out.addAll(await fetchFundNavs(
            missingEtf.map((e) => e.code).toList(),
            kinds: {for (final a in missingEtf) a.code: a.kind},
          ));
        } on MarketException catch (_) {
          // 兜底也失败就保持缺行情，UI 会显示「无行情」
        }
      }
    }
    if (out.isEmpty && errors.isNotEmpty) {
      throw MarketException(errors.join('；'));
    }
    return out;
  }

  /// 场外基金：单位净值 / 盘中估值（一次最多 50 只）
  ///
  /// 这个接口同时覆盖场内基金：对 ETF/LOF 会额外返回交易所现价
  /// `NEWPRICE` / `CHANGERATIO` / `HQDATE`，因此也能当作 push2 的兜底源。
  Future<Map<String, Quote>> fetchFundNavs(
    List<String> codes, {
    Map<String, AssetKind>? kinds,
  }) async {
    final out = <String, Quote>{};
    final clean = codes
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (clean.isEmpty) return out;

    for (var i = 0; i < clean.length; i += 50) {
      final chunk = clean.sublist(i, math.min(i + 50, clean.length));
      final url = 'https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo'
          '?pageIndex=1&pageSize=${chunk.length}'
          '&plat=Android&appType=ttjj&product=EFund&Version=1&deviceid=dsh'
          '&Fcodes=${chunk.join(',')}';

      final body = await _get(url);
      final dynamic json = jsonDecode(body);
      if (json is! Map) continue;
      final datas = json['Datas'];
      if (datas is! List) continue;

      for (final raw in datas) {
        if (raw is! Map) continue;
        final code = _str(raw['FCODE']);
        if (code.isEmpty) continue;

        final nav = _num(raw['NAV']);
        final gsz = _num(raw['GSZ']);
        final newPrice = _num(raw['NEWPRICE']); // 场内基金的交易所现价

        double price;
        double chg;
        String priceType;
        String dateRaw;
        if (gsz > 0) {
          // 盘中估值优先（最接近实时）
          price = gsz;
          chg = _num(raw['GSZZL']);
          priceType = 'est';
          dateRaw = _str(raw['GZTIME']);
        } else if (newPrice > 0) {
          // 场内基金：用交易所现价
          price = newPrice;
          chg = _num(raw['CHANGERATIO']);
          priceType = 'price';
          final hq = _str(raw['HQDATE']);
          dateRaw = hq.isNotEmpty ? hq : _str(raw['PDATE']);
        } else {
          price = nav;
          chg = _num(raw['NAVCHGRT']);
          priceType = 'nav';
          dateRaw = _str(raw['PDATE']);
        }
        if (price <= 0) continue;

        final denom = 1 + chg / 100;
        out[code] = Quote(
          code: code,
          kind: kinds?[code] ?? AssetKind.fund,
          name: _str(raw['SHORTNAME']),
          price: price,
          prevClose: denom.abs() > 1e-9 ? price / denom : 0,
          changePct: chg,
          priceType: priceType,
          infoDate: _isoFromCompact(dateRaw),
          updatedAt: DateTime.now(),
        );
      }
    }
    return out;
  }

  /// 股票 / ETF：交易所行情
  /// 按代码查一条行情，用来给「行情指标」查名字
  ///
  /// 支持指数与 ETF/股票：
  /// - 带前缀：`sh000300`（沪深300指数）、`sz399006`（创业板指）
  /// - 直接给 6 位代码：按 5/6→沪、0/1/2/3→深 判断（`510300` → 沪市 ETF）
  /// - 港美股（`hkHSI` / `gb_$dji`）东财这个接口的 secid 规则不同，这里不做，
  ///   调用方会退回「用代码当名字」
  ///
  /// 返回 `(code, name, price, changePct)`；查不到或没行情返回 null。
  Future<({String code, String name, double price, double changePct})?>
      lookupIndex(String rawCode) async {
    final code = normalizeIndexCode(rawCode);
    final m = RegExp(r'^(sh|sz|bj)(\d{6})$').firstMatch(code);
    if (m == null) return null;
    final secid = switch (m.group(1)) {
      'sh' => '1.${m.group(2)}',
      _ => '0.${m.group(2)}',
    };
    final url = 'https://push2.eastmoney.com/api/qt/ulist.np/get'
        '?fltt=2&invt=2&ut=$_ut&fields=f2,f3,f12,f14&secids=$secid';
    final body = await _get(url);
    final dynamic json = jsonDecode(body);
    if (json is! Map) return null;
    final data = json['data'];
    if (data is! Map) return null;
    final diff = data['diff'];
    final items = diff is List
        ? diff.whereType<Map>()
        : (diff is Map ? [diff] : const <Map>[]);
    for (final it in items) {
      final name = _str(it['f14']);
      if (name.isEmpty) continue;
      return (
        code: _str(it['f12']).isEmpty ? code : _str(it['f12']),
        name: name,
        price: _num(it['f2']),
        changePct: _num(it['f3']),
      );
    }
    return null;
  }

  Future<Map<String, Quote>> fetchExchangeQuotes(List<Asset> assets) async {
    final out = <String, Quote>{};
    final byCode = <String, Asset>{};
    final secidByCode = <String, String>{};
    for (final a in assets) {
      final s = secidFor(a);
      if (s == null) continue;
      if (byCode.containsKey(a.code)) continue;
      byCode[a.code] = a;
      secidByCode[a.code] = s;
    }
    if (secidByCode.isEmpty) return out;

    Future<List<Map>> query(Iterable<String> ids) async {
      if (ids.isEmpty) return const [];
      final url = 'https://push2.eastmoney.com/api/qt/ulist.np/get'
          '?fltt=2&invt=2&ut=$_ut&fields=f2,f3,f4,f12,f14,f18,f297'
          '&secids=${ids.join(',')}';
      final body = await _get(url);
      final dynamic json = jsonDecode(body);
      if (json is! Map) return const [];
      final data = json['data'];
      if (data is! Map) return const [];
      final diff = data['diff'];
      if (diff is List) return diff.whereType<Map>().toList();
      if (diff is Map) return [diff];
      return const [];
    }

    void absorb(List<Map> items) {
      for (final it in items) {
        final code = _str(it['f12']);
        if (code.isEmpty) continue;
        final price = _num(it['f2']);
        if (price <= 0) continue;
        out[code] = Quote(
          code: code,
          kind: byCode[code]?.kind ?? AssetKind.stock,
          name: _str(it['f14']),
          price: price,
          prevClose: _num(it['f18']),
          changePct: _num(it['f3']),
          priceType: 'price',
          // f297 = 该报价的交易日（如 20260911），用于区分「今日收益」与「前日收益」
          infoDate: _isoFromCompact(_str(it['f297'])),
          updatedAt: DateTime.now(),
        );
      }
    }

    MarketException? bulkError;
    try {
      absorb(await query(secidByCode.values));
    } on MarketException catch (e) {
      // 批量接口被限流/断连是常态，交给下面的逐只兜底
      bulkError = e;
    }

    // 逐只兜底
    //
    // 批量接口 `ulist.np/get` 在部分网络/机房 IP 下会被**直接断开连接**
    // （表现为 Connection closed，Dart 侧连 502 都拿不到），
    // 而单只接口 `stock/get` 稳定可用，还返回 UTF-8 JSON（中文名不乱码），
    // 所以它既兜底行情，也顺带探明北交所的 secid 前缀。
    final missing = secidByCode.entries
        .where((e) => !out.containsKey(e.key))
        .toList();
    for (var i = 0; i < missing.length; i += 4) {
      final chunk = missing.sublist(i, math.min(i + 4, missing.length));
      final got = await Future.wait(chunk.map((e) async {
        final a = byCode[e.key]!;
        try {
          return await _fetchOneQuote(a, e.value) ??
              await _fetchOneQuote(a, flipSecid(e.value));
        } on MarketException {
          return null;
        }
      }));
      for (final q in got) {
        if (q != null) out[q.code] = q;
      }
    }

    // 一个标的都没拿到、且批量接口本身报了错 → 把原因抛出去让界面能提示，
    // 而不是静默显示「无行情」
    if (out.isEmpty && bulkError != null) throw bulkError;
    return out;
  }

  /// 单只股票 / ETF 行情（批量接口不可用时的兜底）
  Future<Quote?> _fetchOneQuote(Asset a, String secid) async {
    final body = await _get('https://push2.eastmoney.com/api/qt/stock/get'
        '?fltt=2&invt=2&ut=$_ut'
        '&fields=f43,f57,f58,f60,f169,f170,f86,f297&secid=$secid');
    final dynamic json = jsonDecode(body);
    if (json is! Map) return null;
    final data = json['data'];
    if (data is! Map) return null;

    final code = _str(data['f57']);
    final price = _num(data['f43']);
    if (code.isEmpty || price <= 0) return null;

    return Quote(
      code: code,
      kind: a.kind,
      name: _str(data['f58']),
      price: price,
      prevClose: _num(data['f60']),
      changePct: _num(data['f170']),
      priceType: 'price',
      // f86 是行情最后更新时刻（秒级时间戳），比 f297 可靠：
      // f297 对个股返回报告期（如 20260630）、对 ETF 直接返回「-」。
      infoDate: _isoFromEpoch(_num(data['f86'])) ??
          _isoFromCompact(_str(data['f297'])),
      updatedAt: DateTime.now(),
    );
  }

  /// 秒级时间戳 → `2026-09-11`；越界返回 null 由调用方另寻来源
  static String? _isoFromEpoch(double sec) {
    if (sec <= 0) return null;
    // 与净值时间戳同样处理：固定按 UTC+8 折算，避免设备时区把日期挪走一天
    final iso = cnDayFromEpochMillis((sec * 1000).round());
    final d = DateTime.tryParse(iso);
    if (d == null || d.year < 2000 || d.year > 2200) return null;
    return iso;
  }

  /// 关键词搜索标的（支持基金、股票、ETF）
  Future<List<Asset>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];

    final results = <String, Asset>{};
    final enc = Uri.encodeComponent(kw);

    // 1) 股票 / ETF（交易所标的优先，带市场信息）
    try {
      final body = await _get(
        'https://searchapi.eastmoney.com/api/suggest/get'
        '?input=$enc&type=14&token=$_searchToken&count=20',
      );
      final dynamic json = jsonDecode(body);
      if (json is Map) {
        final table = json['QuotationCodeTable'];
        if (table is Map) {
          final datas = table['Data'];
          if (datas is List) {
            for (final raw in datas) {
              if (raw is! Map) continue;
              final code = _str(raw['Code']);
              if (code.length != 6) continue;
              final kind = _kindFromSecurityType(
                _str(raw['SecurityTypeName']),
                _str(raw['Classify']),
              );
              if (kind == null) continue;
              final quoteId = _str(raw['QuoteID']);
              final market = quoteId.startsWith('1.')
                  ? 'SH'
                  : (quoteId.startsWith('0.') ? 'SZ' : marketFor(code));
              results['${kind.name}:$code'] =
                  Asset(code: code, name: _str(raw['Name']), kind: kind, market: market);
            }
          }
        }
      }
    } on MarketException {
      // 忽略，继续尝试基金搜索
    }

    // 2) 场外基金
    try {
      final body = await _get(
        'https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx?m=1&key=$enc',
      );
      final dynamic json = jsonDecode(body);
      if (json is Map) {
        final datas = json['Datas'];
        if (datas is List) {
          for (final raw in datas) {
            if (raw is! Map) continue;
            final code = _str(raw['CODE']);
            if (code.isEmpty) continue;
            // 已经在交易所结果里出现过（同一代码）就跳过
            final dup = results.keys.any((k) => k.endsWith(':$code'));
            if (dup) continue;
            results['fund:$code'] =
                Asset(code: code, name: _str(raw['NAME']), kind: AssetKind.fund);
          }
        }
      }
    } on MarketException {
      // 忽略
    }

    return results.values.toList();
  }

  /// 按代码解析标的名称与类型
  Future<Asset?> resolveByCode(String code, AssetKind kind) async {
    final c = code.trim();
    if (c.isEmpty) return null;

    if (kind == AssetKind.fund) {
      try {
        final m = await fetchFundNavs([c]);
        final q = m[c];
        if (q != null) {
          return Asset(code: c, name: q.name, kind: AssetKind.fund);
        }
      } on MarketException {
        return null;
      }
      return null;
    }

    final probe = Asset(code: c, name: '', kind: kind, market: marketFor(c));
    try {
      final m = await fetchExchangeQuotes([probe]);
      final q = m[c];
      if (q != null) {
        return Asset(code: c, name: q.name, kind: kind, market: probe.market);
      }
    } on MarketException {
      return null;
    }
    return null;
  }

  static AssetKind? _kindFromSecurityType(String typeName, String classify) {
    if (classify == 'AStock') return AssetKind.stock;
    if (typeName.contains('ETF') || typeName.contains('LOF')) return AssetKind.etf;
    if (typeName.contains('基金')) return AssetKind.etf;
    if (typeName.contains('可转债') || typeName.contains('债券')) return AssetKind.other;
    return null;
  }

  static double _num(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  /// 把 `20260911` 或 `2026-09-11 15:00` 统一成 `2026-09-11`
  static String _isoFromCompact(String v) {
    final s = v.trim();
    if (RegExp(r'^\d{8}$').hasMatch(s)) {
      return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}';
    }
    if (s.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
      return s.substring(0, 10);
    }
    return s.length >= 10 ? s.substring(0, 10) : '';
  }

  static String _str(Object? v) => v == null ? '' : v.toString();
}
