/// 中证官网 `indexCsiDsPe`：**PE（`peg`）历史** → 自己算 PE 分位。
///
/// ```
/// GET https://www.csindex.com.cn/csindex-home/perf/indexCsiDsPe?indexCode=<指数代码>
/// ```
///
/// 为什么需要它：**蛋卷只收录 35 个指数**（357 只候选里的 10%），低估榜要覆盖更多
/// 主流指数就得自己算分位。这条接口按指数返回**完整 PE 历史**（比 `index-perf` 的
/// ~1MB 小），实测：上证指数 340KB/6.8s、中证A500 47KB/3.6s、红利质量 162KB/13.7s、
/// 中证A50 61KB/6.1s —— **一次请求就能算出一个指数**，所以只给"蛋卷没有、又是主流
/// 宽基/红利"的那几只补位（2026-09-29 补了 9 只）。
///
/// ⚠️ **与蛋卷口径不同**（窗口与编制口径都可能不一样：实测科创50 自算 0.708 / 蛋卷
/// 0.790，证券公司 自算 0.022 / 蛋卷 0.000）→ 榜单里**每行必须标出"分位是谁给的"**，
/// 别把两个源混成一个数。自算窗口起点随指数不同（2011 起或上市起），界面要标出来。
///
/// ⚠️ **深证系没有数据**：`399001` 深证成指、`399006` 创业板指 都返回空（这个接口
/// 只覆盖中证/上证系）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

double? _numOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim());
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 自算出来的 PE 与分位
class CsiPeStat {
  /// 最新一天的 PE
  final double pe;

  /// 最新 PE 在**这段历史**里的分位（0~1）
  final double percentile;

  /// 最新日期（`yyyyMMdd`）
  final String date;

  /// 历史窗口起点（`yyyyMMdd`）
  final String windowStart;

  /// 参与算分位的交易日数
  final int samples;

  const CsiPeStat({
    required this.pe,
    required this.percentile,
    required this.date,
    required this.windowStart,
    required this.samples,
  });

  Map<String, Object?> toJson() => {
        'pe': pe,
        'pct': percentile,
        'date': date,
        'from': windowStart,
        'n': samples,
      };

  static CsiPeStat? fromJson(Object? json) {
    if (json is! Map) return null;
    final pe = _numOrNull(json['pe']);
    final pct = _numOrNull(json['pct']);
    final date = _str(json['date']);
    if (pe == null || pct == null || date.isEmpty) return null;
    return CsiPeStat(
      pe: pe,
      percentile: pct,
      date: date,
      windowStart: _str(json['from']),
      samples: _numOrNull(json['n'])?.toInt() ?? 0,
    );
  }
}

/// 纯函数：从 `indexCsiDsPe` 响应里算出最新 PE 与分位（形状照 2026-09-29 实测）
///
/// 分位定义：**最新 PE 在这段历史里"低于它的样本占比"** —— 越小越低估。
/// `peg` 缺失的点（债券类指数）跳过；样本为空返回 null（让界面如实说没取到）。
CsiPeStat? parseCsiPeStat(String body) {
  Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (j is! Map) return null;
  final rows = j['data'];
  if (rows is! List) return null;
  final points = <(String, double)>[];
  for (final r in rows) {
    if (r is! Map) continue;
    final d = _str(r['tradeDate']);
    final p = _numOrNull(r['peg']);
    if (d.isEmpty || p == null) continue;
    points.add((d, p));
  }
  if (points.isEmpty) return null;
  points.sort((a, b) => a.$1.compareTo(b.$1)); // 官网是升序，但不依赖它
  final last = points.last;
  final below = points.where((e) => e.$2 < last.$2).length;
  return CsiPeStat(
    pe: last.$2,
    percentile: points.length <= 1 ? 0.5 : below / points.length,
    date: last.$1,
    windowStart: points.first.$1,
    samples: points.length,
  );
}

/// 「中证官网 PE 历史 → 自算分位」的取数客户端
class CsiPeHistSource {
  final http.Client _client;
  final String base;

  CsiPeHistSource({
    http.Client? client,
    this.base = 'https://www.csindex.com.cn',
  }) : _client = client ?? http.Client();

  String urlOf(String code) =>
      '$base/csindex-home/perf/indexCsiDsPe?indexCode=${Uri.encodeQueryComponent(code.trim())}';

  /// 取不到（接口不覆盖 / 网络失败）一律返回 null，**界面照实说"没取到"**
  Future<CsiPeStat?> latest(
    String code, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    try {
      final res = await _client.get(Uri.parse(urlOf(c)), headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.csindex.com.cn/',
      }).timeout(timeout);
      if (res.statusCode != 200) return null;
      return parseCsiPeStat(utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }
}
