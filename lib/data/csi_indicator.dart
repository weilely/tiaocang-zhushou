/// 中证指数官网 `indicator.xls`：**指数股息率 + PE**（覆盖全部中证指数）。
///
/// ```
/// GET https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/file/
///     autofile/indicator/<指数代码>indicator.xls
/// ```
///
/// ⚠️ **只有 `.xls` 一种格式**（`.csv` / `.json` / `.xlsx` 全 404），而且是
/// **OLE2 / BIFF8 的老式 Excel** —— 用 `excel_plus`（MIT、纯 Dart、内置 BIFF8
/// 解析器）来读，**不自己写 OLE2/BIFF**（用户 2026-09-29 口径：「接第三方库解析」）。
///
/// **实测（2026-09-29，真实文件）**：1 个工作表、21 行 × 10 列 = 表头 + **20 个
/// 交易日**（**最新在前**）。列名中英合写：
/// `日期Date | 指数代码Index Code | 指数中文全称Chinese Name(Full) |
///  指数中文简称Index Chinese Name | 指数英文全称 | 指数英文简称 |
///  市盈率1（总股本）P/E1 | 市盈率2（计算用股本）P/E2 |
///  股息率1（总股本）D/P1 | 股息率2（计算用股本）D/P2`
///
/// 样本值：`000922` → PE1 **8.74** / D/P1 4.21 / **D/P2 4.27**（蛋卷同一天 4.26，
/// 两者口径接近但不完全一致）；`931468`（蛋卷没收录）→ D/P2 **2.93** ✓；
/// **国证 `980xxx` → 404**（不是中证指数，本来也没有源）。
///
/// 口径取舍：**股息率用 `D/P2`（计算用股本）**、**PE 用 `P/E1`（总股本）** ——
/// 取与官网页面/蛋卷更接近的那一侧；两个值都留着，**界面必须注明来源**
/// （中证官网口径 ≠ 蛋卷口径，别混成一个数）。
library;

import 'dart:convert';

import 'package:excel_plus/excel_plus.dart';
import 'package:http/http.dart' as http;

/// 中证官网 `indicator.xls` 里的一天
class CsiIndicator {
  /// `yyyyMMdd`（官网原样）
  final String date;

  /// 指数代码
  final String code;

  /// 指数中文简称（如 `中证红利`）
  final String name;

  /// 市盈率1（总股本）
  final double? pe1;

  /// 市盈率2（计算用股本）
  final double? pe2;

  /// 股息率1（总股本），百分数：4.21 = 4.21%
  final double? dp1;

  /// 股息率2（计算用股本），百分数：4.27 = 4.27%
  final double? dp2;

  const CsiIndicator({
    required this.date,
    this.code = '',
    this.name = '',
    this.pe1,
    this.pe2,
    this.dp1,
    this.dp2,
  });

  /// 界面上默认用的 PE：总股本口径（与官网页面一致）
  double? get pe => pe1 ?? pe2;

  /// 界面上默认用的股息率（**百分数**，4.27 = 4.27%）：计算用股本口径
  double? get dividendYield => dp2 ?? dp1;
}

String _cell(List<String> row, int i) =>
    (i >= 0 && i < row.length) ? row[i].trim() : '';

double? _num(List<String> row, int i) {
  final s = _cell(row, i).replaceAll(',', '');
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// 在表头里找某一列：按 [keys] 顺序找**第一个**命中的列，[exclude] 里的词命中则跳过。
int _colOf(
  List<String> head,
  List<String> keys, {
  List<String> exclude = const [],
}) {
  for (final k in keys) {
    for (var i = 0; i < head.length; i++) {
      final h = head[i];
      if (h.contains(k) && !exclude.any(h.contains)) return i;
    }
  }
  return -1;
}

/// **纯函数**：从解出来的表格里取**日期最大**的那一行（官网是最新在前，但不依赖顺序）
///
/// 列名可能随官网调整，所以按**关键字定位列**（日期/指数代码/简称/市盈率1/2/股息率1/2），
/// 认不出来就返回 null —— 让界面如实说"没取到"，别编。
CsiIndicator? parseIndicatorGrid(List<List<String>> grid) {
  if (grid.isEmpty) return null;
  var headRow = -1;
  for (var i = 0; i < grid.length; i++) {
    final r = grid[i];
    if (r.any((v) => v.contains('日期') || v.trim().startsWith('Date'))) {
      headRow = i;
      break;
    }
  }
  if (headRow < 0) return null;
  final head = grid[headRow];
  final iDate = _colOf(head, ['日期']);
  if (iDate < 0) return null;
  final iCode = _colOf(head, ['指数代码']);
  // 「指数中文简称Index Chinese Name」——别撞上「全称」或「英文全称」
  final iName = _colOf(head, ['简称'], exclude: ['英文']);
  final iPe1 = _colOf(head, ['市盈率1']);
  final iPe2 = _colOf(head, ['市盈率2']);
  final iDp1 = _colOf(head, ['股息率1']);
  final iDp2 = _colOf(head, ['股息率2']);

  CsiIndicator? best;
  for (final r in grid.skip(headRow + 1)) {
    final date = _cell(r, iDate);
    if (date.isEmpty) continue;
    if (best != null && date.compareTo(best.date) <= 0) continue;
    best = CsiIndicator(
      date: date,
      code: _cell(r, iCode),
      name: _cell(r, iName),
      pe1: _num(r, iPe1),
      pe2: _num(r, iPe2),
      dp1: _num(r, iDp1),
      dp2: _num(r, iDp2),
    );
  }
  return best;
}

/// 直接解一段 `.xls` 字节（**读不了就返回 null，不抛**）
CsiIndicator? parseIndicatorBytes(List<int> bytes) {
  try {
    final excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return null;
    final sheet = excel.tables[excel.tables.keys.first];
    if (sheet == null) return null;
    final grid = [
      for (final row in sheet.rows)
        [for (final cell in row) cell?.value?.toString() ?? ''],
    ];
    return parseIndicatorGrid(grid);
  } catch (_) {
    return null; // 坏文件/格式变了都走这里，界面照实说"没取到"
  }
}

/// 「中证官网指数估值指标」取数
class CsiIndicatorSource {
  final http.Client _client;
  final String base;

  CsiIndicatorSource({
    http.Client? client,
    this.base = 'https://oss-ch.csindex.com.cn',
  }) : _client = client ?? http.Client();

  static const _path =
      '/static/html/csindex/public/uploads/file/autofile/indicator';

  /// 某个指数代码的 `.xls` 地址（也方便直接粘到浏览器里核对）
  String urlOf(String code) => '$base$_path/${code.trim()}indicator.xls';

  /// 取最近一天；取不到（官网不认这个代码 / 网络失败 / 文件读不了）返回 null
  Future<CsiIndicator?> latest(
    String code, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    try {
      final res = await _client.get(Uri.parse(urlOf(c)), headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.csindex.com.cn/',
      }).timeout(timeout);
      if (res.statusCode != 200) return null;
      return parseIndicatorBytes(res.bodyBytes);
    } catch (_) {
      return null;
    }
  }
}

/// 让测试/调试能把一段 base64 直接喂进来（不想在测试里硬编码字节数组）
CsiIndicator? parseIndicatorBase64(String b64) {
  try {
    return parseIndicatorBytes(base64Decode(b64));
  } catch (_) {
    return null;
  }
}
