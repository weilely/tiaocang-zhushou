import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'market_api.dart';

/// 同花顺官方金融数据服务（fuyao）REST 客户端。
///
/// 作为行情「第三路」备用源：东财 push2 挂 / 新浪兜底失败时自动切过来。
/// 与东财/新浪不同，它需要**用户自填**的 API Key（`db.setting('hithinkApiKey')`），
/// 未配置时所有方法返回 `const {}`，调用方照旧走东财/新浪。
///
/// - 官网/取 Key：https://fuyao.aicubes.cn/admin
/// - 契约：所有远端端点 GET + `X-api-key` 头；成功判定是信封 `code == 0`
///   （**HTTP 200 不代表成功**），错误码 1xxx 参数 / 2xxx 认证 / 3xxx 数据
///   / 4001 限流 / 5xxx 服务端异常。
class HithinkApi {
  HithinkApi(this._client);

  final http.Client _client;

  void dispose() => _client.close();

  /// 远端取数默认 Base（A 股/指数快照共用）
  static const String base = 'https://fuyao.aicubes.cn';

  /// 未配置 Key 时调用方快速判定，避免白打请求
  bool enabled(String apiKey) => apiKey.trim().isNotEmpty;

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

  /// 拉取一批标的的**指数**行情快照。
  ///
  /// [codes] 是带前缀代码列表（`sh000001` 等）。能唯一确定市场的才转换；
  /// 返回 `完整 thscode -> {price, prevPrice, changePct, change}`。
  /// [apiKey] 未配置或请求失败返回空 Map，**不抛**（由调用方决定沿用旧值/走其它源）。
  Future<Map<String, dynamic>> indexSnapshots(
    List<String> codes,
    String apiKey,
  ) async {
    if (!enabled(apiKey)) return const {};
    final ths = <String>[];
    for (final c in codes) {
      final t = thscodeFor(c);
      if (t != null && !ths.contains(t)) ths.add(t);
    }
    if (ths.isEmpty) return const {};
    final out = <String, dynamic>{};
    // 指数域 thscode 入参「不接受逗号，单次仅支持一个」，逐个取
    for (final t in ths) {
      try {
        final item = await _get(
          '/api/a-share-index/prices/snapshot?thscodes=$t',
          apiKey,
        );
        final data = item['data'];
        if (data is Map) {
          final arr = data['item'];
          if (arr is List) {
            for (final raw in arr) {
              if (raw is! Map) continue;
              final price = _num(raw['last_price']);
              if (price <= 0) continue;
              out[t] = {
                'price': price,
                'prevPrice': _num(raw['prev_price']),
                'changePct': _num(raw['price_change_ratio_pct']),
                'change': _num(raw['price_change']),
              };
            }
          }
        }
      } on HithinkException {
        // 限流/认证/数据缺失：跳过该只，不阻塞整批
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
    final ths = <String>[];
    for (final c in codes) {
      final t = thscodeFor(c);
      if (t != null && !ths.contains(t)) ths.add(t);
    }
    if (ths.isEmpty) return const {};
    try {
      final item = await _get(
        '/api/a-share/prices/snapshot?thscodes=${ths.join(',')}',
        apiKey,
      );
      final out = <String, dynamic>{};
      final data = item['data'];
      if (data is Map) {
        final arr = data['item'];
        if (arr is List) {
          for (final raw in arr) {
            if (raw is! Map) continue;
            // 用完整 thscode 作键，避免 `000001.SH`（上证指数）与
            // `000001.SZ`（平安银行）都退化成 `000001` 撞在一起
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
        }
      }
      return out;
    } on HithinkException {
      return const {};
    }
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
