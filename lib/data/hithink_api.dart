import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'market_api.dart';

/// 同花顺里「这只标的该走哪个行情接口」
///
/// **不是一个接口通吃**（实测确认）：
/// - [indexQuote] 指数 → `/api/a-share-index/prices/snapshot`，支持逗号批量
/// - [stockQuote] A 股股票 → `/api/a-share/prices/snapshot`，支持逗号批量
/// - [fundQuote] 场内基金 ETF/LOF → `/api/fund/market/snapshot`，**参数单数、一次一个**
///   （把 ETF 代码丢给 A 股快照会得到 `1002 Unknown A-share thscode`）
///
/// 取值不能叫 `index`：Dart 的枚举自带 `Enum.index`，会撞名编译不过。
enum HithinkKind { indexQuote, stockQuote, fundQuote }

/// 同花顺官方金融数据服务（fuyao）REST 客户端。
///
/// 用途：用户配了 API Key 时作为**优先**行情源（东财 push2 会整站 502、
/// 新浪是兜底），拿不到或品种不覆盖的再由调用方补缺。
/// 与东财/新浪不同，它需要**用户自填**的 Key（`db.setting('hithinkApiKey')`），
/// 未配置时所有方法返回 `const {}`，调用方照旧走东财/新浪。
///
/// - 官网/取 Key：https://fuyao.aicubes.cn/admin
/// - 契约：所有远端端点 GET + `X-api-key` 头；成功判定是信封 `code == 0`
///   （**HTTP 200 不代表成功**），错误码 1xxx 参数 / 2xxx 认证 / 3xxx 数据
///   / 4001 限流 / 5xxx 服务端异常。
/// - 快照**不返回中文名**（只有 thscode/ticker），要名字得另走 meta 域。
class HithinkApi {
  HithinkApi(this._client);

  final http.Client _client;

  void dispose() => _client.close();

  /// 远端取数默认 Base（A 股/指数/场内基金快照共用）
  static const String base = 'https://fuyao.aicubes.cn';

  /// 未配置 Key 时调用方快速判定，避免白打请求
  bool enabled(String apiKey) => apiKey.trim().isNotEmpty;

  /// 拉取**基础数据**（代码表）：`/api/meta/tickers/list`
  ///
  /// [assetType] 用官方枚举：`a-share` / `a-share-index` / `fund-otc` /
  /// `fund-etf` / `fund-lof` / `fund-reits` / `forex` / `futures` / `options`，
  /// 可用逗号合并多值（如 `fund-otc,fund-etf,fund-lof`）。
  ///
  /// 与快照类方法不同，这里**失败会抛** [HithinkException]：调用方要靠它决定
  /// 「回落到原来的东财/新浪通道」，不能把失败当成"没有数据"（那就是静默降级了）。
  /// 服务端单页上限 10000，内部按 offset 翻页直到不满一页。
  Future<List<Map<String, dynamic>>> tickersList(
    String assetType,
    String apiKey, {
    int limit = 10000,
    int maxPages = 20,
  }) async {
    if (!enabled(apiKey)) return const [];
    final out = <Map<String, dynamic>>[];
    for (var page = 0; page < maxPages; page++) {
      final item = await _get(
        '/api/meta/tickers/list?asset_type=$assetType'
        '&limit=$limit&offset=${page * limit}',
        apiKey,
      );
      final data = item['data'];
      final arr = (data is Map) ? data['item'] : null;
      if (arr is! List) break;
      for (final raw in arr) {
        if (raw is Map) out.add(Map<String, dynamic>.from(raw));
      }
      if (arr.length < limit) break; // 不满一页 = 取尽了
    }
    return out;
  }

  /// 把「带市场前缀的代码」规范化成同花顺 `thscode`（`600519.SH`）。
  ///
  /// 输入兼容 `sh000001` / `sz399001` / `bj899050` / `510300`（裸 6 位）等：
  /// 前缀 sh/sz/bj → `.SH`/`.SZ`/`.BJ`；裸 6 位复用 [MarketService] 那套
  /// **已有的**市场归属判断（北交所 920xxx / 8xxxxx 也是它判的），
  /// 不在这里另写一套号段规则，避免两处口径打架。
  /// **返回 null 表示无法确定市场（调用方跳过）**：同花顺要求不猜交易所后缀。
  static String? thscodeFor(String raw) {
    final s = raw.trim().toLowerCase();
    final m = RegExp(r'^(sh|sz|bj)(\d{6})$').firstMatch(s);
    if (m != null) {
      final suffix = switch (m.group(1)) {
        'sh' => '.SH',
        'sz' => '.SZ',
        _ => '.BJ',
      };
      return '${m.group(2)}$suffix';
    }
    if (RegExp(r'^\d{6}$').hasMatch(s)) {
      final suffix = MarketService.isBeijingCode(s)
          ? '.BJ'
          : (MarketService.isShanghaiCode(s) ? '.SH' : '.SZ');
      return '$s$suffix';
    }
    // 已经是 `600519.SH` 形式原样返回（转大写）
    final t = RegExp(r'^\d{6}\.(SH|SZ|BJ)$').firstMatch(raw.trim().toUpperCase());
    return t?.group(0);
  }

  /// 拉取一批**场内基金**（ETF / LOF）行情快照。
  ///
  /// **跟股票不是同一个接口**：把 ETF 代码丢给 A 股快照会得到
  /// `1002 Unknown A-share thscode`（实测 510300.SH / 159915.SZ /
  /// 501029.SH / 588000.SH 全中），必须走 `/api/fund/market/snapshot`。
  /// 该接口 `thscode` 是**单数、一次只收一个**（逗号直接 1002），
  /// 所以这里按 [chunk] 个一组并发，别一只一只串着等。
  ///
  /// 文档写「仅支持 ETF，LOF 返回 3004」，但实测 LOF（`501029.SH`）同样有价，
  /// 所以不按类型预筛，能拿到就用。拿不到的（场外基金 3001 等）静默跳过。
  Future<Map<String, dynamic>> fundSnapshots(
    List<String> codes,
    String apiKey, {
    int chunk = 4,
  }) async {
    if (!enabled(apiKey)) return const {};
    final ths = _thsCodes(codes);
    if (ths.isEmpty) return const {};
    final out = <String, dynamic>{};
    for (var i = 0; i < ths.length; i += chunk) {
      final part = ths.sublist(i, math.min(i + chunk, ths.length));
      final got = await Future.wait(part.map((t) => _oneFund(t, apiKey)));
      for (final m in got) {
        out.addAll(m);
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> _oneFund(String thscode, String apiKey) async {
    try {
      final item =
          await _get('/api/fund/market/snapshot?thscode=$thscode', apiKey);
      return _parseSnapshot(item);
    } on HithinkException {
      // 场外基金（3001 Fund not found）、不支持的类型：跳过，交给东财/新浪
      return const {};
    }
  }

  /// 拉取一批标的的**指数**行情快照。
  ///
  /// [codes] 是带前缀代码列表（`sh000001` 等）。能唯一确定市场的才转换；
  /// 返回 `完整 thscode -> {price, prevPrice, changePct, change}`。
  /// [apiKey] 未配置或请求失败返回空 Map，**不抛**（由调用方决定补缺/沿用旧值）。
  Future<Map<String, dynamic>> indexSnapshots(
    List<String> codes,
    String apiKey,
  ) async {
    if (!enabled(apiKey)) return const {};
    final ths = _thsCodes(codes);
    if (ths.isEmpty) return const {};
    const path = '/api/a-share-index/prices/snapshot';
    // 文档写「thscode 不接受逗号，单次仅支持一个指数」，但 2026-09 实测
    // `thscodes=A,B` 返回 code=0 / total=2，两条都在。所以先按批量发，
    // 一只指数一个请求的事就省了。
    final out = <String, dynamic>{};
    out.addAll(await _snapshot(path, ths, apiKey));
    // 万一哪天批量真的被拒（语义变化、返回 0 条而不是部分），退回逐个取：
    // 这样"同花顺优先"不会因为一个入参语法变化就整条失效。
    // **只在一条都没回来时才退**：部分缺失是品种本身不覆盖（如板块代码），
    // 逐个重试纯属白打请求。
    if (out.isEmpty && ths.length > 1) {
      for (final t in ths) {
        out.addAll(await _snapshot(path, [t], apiKey));
      }
    }
    return out;
  }

  /// 拉取一批标的的 **A 股/ETF/股票**行情快照（`/api/a-share/prices/snapshot`）。
  ///
  /// 该接口 `thscodes` 支持逗号批量，一次取整批；返回
  /// `完整 thscode -> {price, prevPrice, changePct, change}`。
  /// [apiKey] 未配置或失败返回空 Map。
  Future<Map<String, dynamic>> aShareSnapshots(
    List<String> codes,
    String apiKey,
  ) async {
    if (!enabled(apiKey)) return const {};
    final ths = _thsCodes(codes);
    if (ths.isEmpty) return const {};
    return _snapshot('/api/a-share/prices/snapshot', ths, apiKey);
  }

  /// 代码列表 → 去重后的 thscode 列表（认不出市场的丢掉）
  List<String> _thsCodes(List<String> codes) {
    final ths = <String>[];
    for (final c in codes) {
      final t = thscodeFor(c);
      if (t != null && !ths.contains(t)) ths.add(t);
    }
    return ths;
  }

  /// 发一次快照请求并解析成 `完整 thscode -> 价格记录`；失败/业务错误返回空 Map
  Future<Map<String, dynamic>> _snapshot(
    String path,
    List<String> thscodes,
    String apiKey,
  ) async {
    if (thscodes.isEmpty) return const {};
    try {
      final item = await _get(
        '$path?thscodes=${thscodes.join(',')}',
        apiKey,
      );
      return _parseSnapshot(item);
    } on HithinkException {
      // 限流/认证/数据缺失：返回空，交给调用方补缺或沿用旧值，不打断整轮刷新
      return const {};
    }
  }

  /// 解析快照信封 → `完整 thscode -> {price, prevPrice, changePct, change}`
  ///
  /// 三个快照接口（A 股 / 指数 / 场内基金）的 `data.item[]` 字段名一致，
  /// 所以共用这一段；字段位置拿不准的（价格为 0）直接丢掉，不猜。
  Map<String, dynamic> _parseSnapshot(Map item) {
    final out = <String, dynamic>{};
    final data = item['data'];
    if (data is! Map) return out;
    final arr = data['item'];
    if (arr is! List) return out;
    for (final raw in arr) {
      if (raw is! Map) continue;
      // 用完整 thscode 作键，避免 `000001.SH`（上证指数）与
      // `000001.SZ`（平安银行）都退化成 `000001` 撞在一起。
      // 实测指数响应的 `ticker` 是 `1A0001` 这种，按 ticker 也对不上。
      final t = _str(raw['thscode']);
      if (t.isEmpty) continue;
      final price = _num(raw['last_price']);
      if (price <= 0) continue;
      out[t] = {
        'price': price,
        'prevPrice': _num(raw['prev_price']),
        'changePct': _num(raw['price_change_ratio_pct']),
        'change': _num(raw['price_change']),
      };
    }
    return out;
  }

  /// 通用 GET：返回响应信封（`{code,message,data}`）；`code!=0` 抛 [HithinkException]
  Future<Map> _get(String path, String apiKey) async {
    final url = '$base$path';
    http.Response res;
    try {
      res = await _client
          .get(Uri.parse(url),
              headers: {'X-api-key': apiKey.trim()})
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw HithinkException('同花顺请求超时');
    } catch (e) {
      throw HithinkException('同花顺网络错误：$e');
    }
    if (res.statusCode != 200) {
      // HTTP 层错误（网关 4xx/5xx）
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw HithinkException('同花顺 API Key 无效或无权限');
      }
      throw HithinkException('同花顺 HTTP ${res.statusCode}');
    }
    final dynamic json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (_) {
      throw HithinkException('同花顺响应解析失败');
    }
    if (json is! Map) throw HithinkException('同花顺响应格式异常');
    final code = (json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw HithinkException(
        '同花顺 code=$code ${_str(json['message'])}',
        code: code,
      );
    }
    return json;
  }

  static String _str(Object? v) => v == null ? '' : v.toString();
  static double _num(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }
}

/// 同花顺接口异常（含信封 `code`，便于分类处理）
class HithinkException implements Exception {
  final String message;
  final int code;
  HithinkException(this.message, {this.code = 0});
  @override
  String toString() => message;
}
