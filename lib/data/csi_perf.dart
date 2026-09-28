/// 中证指数官网 `index-perf`：**PE（`peg` 字段）/ 点位 / 成分数**。
///
/// `GET https://www.csindex.com.cn/csindex-home/perf/index-perf?indexCode=<代码>
///      &startDate=YYYYMMDD&endDate=YYYYMMDD`
///
/// 为什么单独一条：**这是唯一能"全量"拿到 PE 的源**（目录里 3001 条中证指数都有，
/// 实测 000922 → 8.7，与蛋卷的 8.6~8.7 对得上），而蛋卷只收录一小部分指数。
/// 所以「对比表」里 PE 这一列走这里，股息率/PB/ROE/分位仍只能走蛋卷。
///
/// ⚠️ 只取**最近一条**：对比要的是"当前值"，不拉长历史（长窗口一次约 250KB，
/// 要算 PE 分位才需要，那属于另一件事）。请求窗口给 45 天是为了跨过长假。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

double? _numOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim());
}

int? _intOrNull(Object? v) => _numOrNull(v)?.toInt();

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 一个交易日的点位与 PE
class CsiPerfPoint {
  /// `yyyyMMdd`（官网原样）
  final String date;

  /// 收盘点位
  final double? close;

  /// **PE**（官网字段名是 `peg`）
  final double? pe;

  /// 成分数
  final int? consNumber;

  /// 官网给的中文名（代码→名称的兜底）
  final String name;

  const CsiPerfPoint({
    required this.date,
    this.close,
    this.pe,
    this.consNumber,
    this.name = '',
  });
}

/// 取「最近一个交易日的点位/PE」
class CsiPerfSource {
  final http.Client _client;
  final String base;

  CsiPerfSource({http.Client? client, this.base = 'https://www.csindex.com.cn'})
      : _client = client ?? http.Client();

  static String _ymd(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';

  /// 取 [code] 最近一条；取不到（代码官网不认/网络失败）返回 null —— **不抛**
  Future<CsiPerfPoint?> latest(
    String code, {
    int days = 45,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    final end = DateTime.now();
    final start = end.subtract(Duration(days: days));
    final url = '$base/csindex-home/perf/index-perf'
        '?indexCode=${Uri.encodeQueryComponent(c)}'
        '&startDate=${_ymd(start)}&endDate=${_ymd(end)}';
    try {
      final res = await _client.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.csindex.com.cn/',
      }).timeout(timeout);
      if (res.statusCode != 200) return null;
      return parseCsiPerfLatest(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on SocketException {
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// 解析 `index-perf` 响应，取**最后一条**（按返回顺序，官网是升序）。
///
/// 纯函数，形状照 2026-09-29 实测响应。
CsiPerfPoint? parseCsiPerfLatest(String body) {
  Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (j is! Map) return null;
  final rows = j['data'];
  if (rows is! List || rows.isEmpty) return null;
  // 官网按日期升序返回，取最后一条；万一不是，就自己挑日期最大的那条
  Map? best;
  for (final r in rows) {
    if (r is! Map) continue;
    if (best == null) {
      best = r;
      continue;
    }
    if (_str(r['tradeDate']).compareTo(_str(best['tradeDate'])) > 0) best = r;
  }
  if (best == null) return null;
  final date = _str(best['tradeDate']);
  if (date.isEmpty) return null;
  return CsiPerfPoint(
    date: date,
    close: _numOrNull(best['close']),
    pe: _numOrNull(best['peg']), // ← 官网把 PE 叫 peg
    consNumber: _intOrNull(best['consNumber']),
    name: _str(best['indexNameCn']),
  );
}
