import '../data/securities_repo.dart';
import 'holding_import.dart';

/// OCR 出来的一行文字（含外接框）
class OcrLine {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// ML Kit 的文本块序号（同一块里的行属于同一张卡片）。
  /// 手工构造时为 0；只有 0/1 两种取值时不拿它分段，以免把整页当一块。
  final int block;

  const OcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.block = 0,
  });

  double get centerY => (top + bottom) / 2;
  double get centerX => (left + right) / 2;
  double get height => (bottom - top).abs();
}

typedef CodeMatcher = Future<SecurityRow?> Function(String code);
typedef NameMatcher = Future<List<SecurityRow>> Function(String name);

/// 一个字段的把握程度
enum FieldTrust {
  /// 有把握（标签直配 / 代码在库里查到 / 数值经过校验）
  ok,

  /// 模糊匹配或推算出来的，建议人工看一眼
  weak,

  /// 没取到
  missing,
}

class HoldingParseResult {
  final List<HoldingImportRow> rows;

  /// 没能归入任何一行的文字数（供 UI 提示「识别质量」）
  final int orphanLines;

  /// 是否认出了表头（认出时按列定位，最可靠）
  final bool headerFound;

  /// 有几行存在「需核对」的字段
  final int reviewRows;

  const HoldingParseResult({
    required this.rows,
    this.orphanLines = 0,
    this.headerFound = false,
    this.reviewRows = 0,
  });
}

// ============================================================
// 一、标签词表：靠"标签"认字段，而不是靠"第几个数"
// ============================================================
//
// 图片版式千奇百怪，但每家券商/基金 App 的**字段名**都差不多。先把标签认出来，
// 再找它旁边的值 —— 这是整个解析的地基。

const Map<String, List<String>> kFieldLabels = {
  'code': ['基金代码', '证券代码', '股票代码', '产品代码', '代码'],
  'name': ['基金名称', '证券名称', '股票名称', '产品名称', '基金简称', '名称', '简称'],
  'shares': ['持有份额', '持仓份额', '可用份额', '持有数量', '持仓数量', '持股数量', '份额', '股数', '数量'],
  'cost': ['成本单价', '持仓成本价', '单位成本价', '单位成本', '成本价', '买入均价', '每股成本', '成本', '均价'],
  'costTotal': ['持仓成本', '参考成本', '总成本', '成本金额'],
  'price': ['单位净值', '最新净值', '最新价', '现价', '净值', '市价'],
  'amount': ['持仓市值', '参考市值', '最新市值', '持有市值', '资产', '市值', '参考金额', '金额'],
  'pnl': ['浮动盈亏', '持仓盈亏', '持有收益', '盈亏', '收益'],
};

/// 归一化：全角→半角、去掉空格与常见分隔符，便于做标签比对
String normalizeText(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    var c = String.fromCharCode(r);
    // 全角字符（！～）折到半角
    if (r >= 0xFF01 && r <= 0xFF5E) {
      c = String.fromCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      c = ' ';
    }
    sb.write(c);
  }
  return sb
      .toString()
      .replaceAll(RegExp(r'[\s:：\-—_、|]'), '')
      .replaceAll(RegExp(r'[（(].*?[）)]'), '')
      .trim();
}

/// 这一小段文字命中了哪个字段的标签？（要求整段基本就是个标签）
///
/// 也认「值粘在标签后面」的写法：OCR 常把 `持有份额 5,021.00` 识别成一句，
/// 这时取最前面那段中文当标签。
String? labelFieldOf(String text, {bool exactOnly = false}) {
  final t = normalizeText(text);
  if (t.isNotEmpty && t.length <= 8) {
    final hit = _matchLabel(t, exactOnly: exactOnly);
    if (hit != null) return hit;
  }
  final m = RegExp(r'^([\u4e00-\u9fa5A-Za-z]{2,8})').firstMatch(t);
  if (m != null) {
    final head = m.group(1)!;
    if (head != t) return _matchLabel(head, exactOnly: true);
  }
  return null;
}

String? _matchLabel(String t, {required bool exactOnly}) {
  String? best;
  var bestLen = 0;
  for (final e in kFieldLabels.entries) {
    for (final label in e.value) {
      final hit = exactOnly ? t == label : (t == label || t.contains(label));
      if (hit && label.length > bestLen) {
        best = e.key;
        bestLen = label.length;
      }
    }
  }
  return best;
}

// ============================================================
// 二、数值：识别 1,234.56 / 1.2万 / 3亿 / 12.5%
// ============================================================

/// OCR 常把数字认错，按字段性质做字符纠正
String _fixDigits(String s) => s
    .replaceAll('O', '0')
    .replaceAll('o', '0')
    .replaceAll('l', '1')
    .replaceAll('I', '1')
    .replaceAll('，', ',')
    .replaceAll('。', '.');

final RegExp _dateLike = RegExp(
    r'\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}|\d{1,2}[-/月]\d{1,2}日?|\d{1,2}:\d{2}');

/// 把一段文本解析成金额/数量（带 万/亿 单位）；认不出返回 null
double? parseAmount(String raw, {double? maxAbs}) {
  final s = _fixDigits(raw)
      .replaceAll(RegExp(r'[¥￥\s]'), '')
      .replaceAll(RegExp(r'(?<=\d),(?=\d)'), '');
  // 日期、时间、百分比都不是我们要的数
  if (_dateLike.hasMatch(s)) return null;
  if (s.contains('%')) return null;
  final m = RegExp(r'^(-?)(\d+(?:\.\d+)?)(万|亿|千)?$').firstMatch(s);
  if (m == null) return null;
  final v = double.tryParse(m.group(2)!);
  if (v == null) return null;
  final unit = m.group(3);
  final scaled = unit == '万'
      ? v * 10000
      : unit == '亿'
          ? v * 100000000
          : unit == '千'
              ? v * 1000
              : v;
  final signed = m.group(1) == '-' ? -scaled : scaled;
  if (maxAbs != null && signed.abs() > maxAbs) return null;
  return signed;
}

/// 6 位基金/股票代码（OCR 可能把 O/I 认错）
///
/// 注意**要按词扫，不能把整行拼起来再找**：像 `510300 沪深300ETF` 这种，
/// 去掉中文后会粘成 `510300300ETF`，6 位数字的边界就没了。
String? parseSecurityCode(String raw) {
  final s = _fixDigits(raw).replaceAll(RegExp(r'[^0-9A-Za-z]'), ' ');
  final tokens = s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  // 先找"整段就是 6 位数字"的
  for (final t in tokens) {
    if (t.length == 6 && RegExp(r'^\d{6}$').hasMatch(t)) return t;
  }
  // 再在词内部找不被夹在数字中间的 6 位数字（如 sh510300）
  final re = RegExp(r'(?<!\d)(\d{6})(?!\d)');
  for (final t in tokens) {
    final m = re.firstMatch(t);
    if (m != null) return m.group(1);
  }
  return null;
}

// ============================================================
// 三、版面还原
// ============================================================

/// 把 OCR 行按纵坐标聚成「表格行」
List<List<OcrLine>> groupLinesIntoRows(List<OcrLine> lines, {double? tolerance}) {
  if (lines.isEmpty) return const [];
  final sorted = List<OcrLine>.from(lines)..sort((a, b) => a.centerY.compareTo(b.centerY));
  final avgHeight = sorted.map((e) => e.height).fold<double>(0, (a, b) => a + b) /
      sorted.length;
  final tol = tolerance ?? (avgHeight <= 0 ? 12.0 : avgHeight * 0.62);

  final rows = <List<OcrLine>>[];
  var current = <OcrLine>[];
  double? anchor;

  for (final l in sorted) {
    if (anchor == null || (l.centerY - anchor).abs() <= tol) {
      current.add(l);
      anchor ??= l.centerY;
      anchor = (anchor * (current.length - 1) + l.centerY) / current.length;
    } else {
      rows.add(current);
      current = [l];
      anchor = l.centerY;
    }
  }
  if (current.isNotEmpty) rows.add(current);

  for (final r in rows) {
    r.sort((a, b) => a.left.compareTo(b.left));
  }
  return rows;
}

/// 分组：一串 OCR 行 + 它的排版信息
class ParseContext {
  final List<OcrLine> lines;
  final List<List<OcrLine>> rows;

  /// 有意义的块数（>1 才拿块做分段）
  final int blockCount;

  ParseContext._(this.lines, this.rows, this.blockCount);

  factory ParseContext.of(List<OcrLine> lines) {
    final blocks = lines.map((e) => e.block).toSet();
    return ParseContext._(lines, groupLinesIntoRows(lines), blocks.length);
  }

  int get avgHeight {
    if (lines.isEmpty) return 0;
    final h = lines.map((e) => e.height).fold<double>(0, (a, b) => a + b) / lines.length;
    return h.round();
  }
}

class _Column {
  final String field;

  /// 该列的 x 中心与左右边界
  final double centerX;
  final double left;
  final double right;

  _Column(this.field, this.centerX, this.left, this.right);
}

/// 表头行 → 列（相邻标签的中点作为列边界）
List<_Column>? inferColumns(List<List<OcrLine>> rows) {
  List<OcrLine>? best;
  var bestHits = 0;
  for (final row in rows) {
    final hits = row.where((c) => labelFieldOf(c.text, exactOnly: false) != null).length;
    // 至少两个标签才当表头；命中多的优先
    if (hits >= 2 && hits > bestHits) {
      bestHits = hits;
      best = row;
    }
  }
  if (best == null) return null;

  final cells = best
      .where((c) => labelFieldOf(c.text, exactOnly: false) != null)
      .toList()
    ..sort((a, b) => a.left.compareTo(b.left));
  // 同一字段只留一个（表头可能拆成两行，这里只取最左的那次）
  final seen = <String>{};
  final picked = <OcrLine>[];
  for (final c in cells) {
    final f = labelFieldOf(c.text, exactOnly: false)!;
    if (seen.add(f)) picked.add(c);
  }
  if (picked.length < 2) return null;

  final cols = <_Column>[];
  for (var i = 0; i < picked.length; i++) {
    final c = picked[i];
    final f = labelFieldOf(c.text, exactOnly: false)!;
    final left = i == 0 ? double.negativeInfinity : (picked[i - 1].right + c.left) / 2;
    final right = i == picked.length - 1 ? double.infinity : (c.right + picked[i + 1].left) / 2;
    cols.add(_Column(f, c.centerX, left, right));
  }
  return cols;
}

/// 一个持仓段：可能是表格里的一行，也可能是卡片模式里的一块
class _Segment {
  final List<List<OcrLine>> rows;
  _Segment(this.rows);

  String get text => rows
      .expand((r) => r)
      .map((e) => e.text.trim())
      .where((t) => t.isNotEmpty)
      .join(' ');
}

// ============================================================
// 四、主流程：认标签 → 分段 → 模糊取值 → 交叉校验
// ============================================================

/// 把 OCR 结果解析成期初持仓行
///
/// 口径（按可靠性从高到低）：
/// 1. **认表头**：全图找标签命中最多的那行当表头，按标签的 x 区间划列，下面每行按列取值；
/// 2. **卡片分段**：没有表头时，用 ML Kit 的文本块（有多个块时）或「6 位代码 / 名称行」做锚点切段，
///    段内再把「标签 → 值」对上（标签和值可以不在同一行，且按横向距离对位）；
/// 3. **模糊匹配**：代码先查库；代码查不到就用名称做相似度打分（含拼音/去后缀）；
/// 4. **校验**：有份额+净值+市值时用 `份额 × 净值 ≈ 市值` 验一下份额，对不上就标出来；
/// 5. 认不出任何标的线索的段**直接丢掉**（计入 orphanLines），不再产出垃圾行。
///
/// 两种版面**都跑一遍取更好的那个**：卡片里的「持有份额 持仓市值」那一行长得很像表头，
/// 只靠启发式判断谁对很容易翻车，让结果自己比出来最稳。
Future<HoldingParseResult> parseHoldingRows(
  List<OcrLine> lines, {
  required CodeMatcher byCode,
  required NameMatcher byName,
}) async {
  final ctx = ParseContext.of(lines);
  if (ctx.rows.isEmpty) {
    return const HoldingParseResult(rows: []);
  }

  final cols = inferColumns(ctx.rows);
  final attempts = <_Attempt>[
    if (cols != null) await _attempt(ctx, cols, byCode: byCode, byName: byName),
    await _attempt(ctx, null, byCode: byCode, byName: byName),
  ];

  var best = attempts.first;
  for (final a in attempts.skip(1)) {
    if (a.score > best.score) best = a;
  }

  return HoldingParseResult(
    rows: best.rows,
    orphanLines: best.orphan,
    headerFound: best.header,
    reviewRows: best.review,
  );
}

class _Attempt {
  final List<HoldingImportRow> rows;
  final int orphan;
  final bool header;
  final int review;
  final int score;

  _Attempt(this.rows, this.orphan, this.header, this.review, this.score);
}

/// 用给定的列（或 null = 卡片模式）解析一遍，并给出"解析得多好"的分数
Future<_Attempt> _attempt(
  ParseContext ctx,
  List<_Column>? cols, {
  required CodeMatcher byCode,
  required NameMatcher byName,
}) async {
  final segments =
      cols != null ? _segmentsByColumns(ctx, cols) : _segmentsByAnchor(ctx);
  final rows = <HoldingImportRow>[];
  var orphan = 0;
  var review = 0;
  var score = 0;

  for (final seg in segments) {
    final r = await _buildRow(seg, cols, byCode: byCode, byName: byName);
    if (r == null) {
      orphan += seg.rows.length;
      continue;
    }
    if (r.needsReview) review++;
    rows.add(r);
    // 分数：配上库最重要，其次是把份额/成本填出来了
    score += r.matched ? 3 : 1;
    if (r.shares != null) score += 2;
    if (r.costPrice != null) score += 2;
  }
  return _Attempt(rows, orphan, cols != null, review, score);
}

/// 表格模式：表头下方、能凑出一个标的的行，各自成段
List<_Segment> _segmentsByColumns(ParseContext ctx, List<_Column> cols) {
  final headerRow = _headerRowIndex(ctx.rows);
  final out = <_Segment>[];
  for (var i = headerRow + 1; i < ctx.rows.length; i++) {
    final row = ctx.rows[i];
    final joined = row.map((e) => e.text).join(' ');
    // 有代码、或有中文名、或至少有 2 个可用数值 → 认为是一行数据
    final hasCode = parseSecurityCode(joined) != null;
    final hasCjk = RegExp(r'[\u4e00-\u9fa5]').hasMatch(joined);
    final nums = _numbersIn(row, cols).length;
    if (!hasCode && !hasCjk && nums < 2) continue;
    out.add(_Segment([row]));
  }
  return out.isEmpty ? _segmentsByAnchor(ctx) : out;
}

/// 卡片模式：**以锚点行为主**（一个「名称/代码」行 = 一张卡片开始，
/// 一直到下一个锚点为止），拿不到锚点时才退回按 ML Kit 文本块切。
///
/// 为什么不以文本块为主：ML Kit 的 block 比"卡片"细得多 ——
/// 一张持仓卡片的名称、市值、份额往往是**好几个不同的 block**，
/// 按块切会把值和标签拆散（实测就是份额/成本全空）。
List<_Segment> _segmentsByAnchor(ParseContext ctx) {
  final byAnchor = _splitByCodeAnchor(ctx.rows);
  if (byAnchor.length > 1 || ctx.blockCount <= 1) return byAnchor;

  // 整页只有一个段、而且确实有多个块：按块切一刀试试
  final byBlock = <int, List<List<OcrLine>>>{};
  for (final row in ctx.rows) {
    final b = row.isEmpty ? 0 : row.first.block;
    (byBlock[b] ??= []).add(row);
  }
  if (byBlock.length <= 1) return byAnchor;
  return [for (final rows in byBlock.values) _Segment(rows)];
}

/// 用「含 6 位代码的行」或「只有长中文的行」当锚点把若干行切成段
///
/// 关键细节：**名称行和紧跟其后的代码行属于同一张卡片**，不能一切两半。
/// 所以只有当"当前段已经拿到代码/名称"之后，遇到新锚点才另起一段。
List<_Segment> _splitByCodeAnchor(List<List<OcrLine>> rows) {
  final out = <_Segment>[];
  var current = <List<OcrLine>>[];
  var currentHasCode = false;
  var currentHasName = false;

  String? codeOf(List<OcrLine> row) =>
      parseSecurityCode(row.map((e) => e.text).join(' '));

  /// 一行基本只有一个长中文串（标的名称）
  bool isNameLine(List<OcrLine> row) {
    final texts = row.map((e) => e.text.trim()).where((t) => t.isNotEmpty).toList();
    if (texts.length > 2) return false;
    for (final t in texts) {
      if (t.length >= 4 &&
          !RegExp(r'\d').hasMatch(t) &&
          labelFieldOf(t) == null &&
          RegExp(r'[\u4e00-\u9fa5]{4,}').hasMatch(t)) {
        return true;
      }
    }
    return false;
  }

  for (final row in rows) {
    final code = codeOf(row);
    final isName = code == null && isNameLine(row);
    // 已经有一段内容了，再来锚点就是新的一段
    final startsNew = (code != null && currentHasCode) ||
        (isName && (currentHasCode || currentHasName));
    if (startsNew && current.isNotEmpty) {
      out.add(_Segment(current));
      current = [];
      currentHasCode = false;
      currentHasName = false;
    }
    if (code != null) currentHasCode = true;
    if (isName) currentHasName = true;
    current.add(row);
  }
  if (current.isNotEmpty) out.add(_Segment(current));

  // 一个锚点都没有 → 整页一段，交给上层按块再试
  if (!currentHasCode && !currentHasName && out.length == 1) {
    return rows.isEmpty ? out : [_Segment(rows)];
  }
  return out;
}

int _headerRowIndex(List<List<OcrLine>> rows) {
  var bestIdx = -1;
  var bestHits = 0;
  for (var i = 0; i < rows.length; i++) {
    final hits =
        rows[i].where((c) => labelFieldOf(c.text, exactOnly: false) != null).length;
    if (hits >= 2 && hits > bestHits) {
      bestHits = hits;
      bestIdx = i;
    }
  }
  return bestIdx;
}

/// 取一行里按列归属到的数值
Map<String, double> _numbersIn(List<OcrLine> row, List<_Column> cols) {
  final out = <String, double>{};
  for (final cell in row) {
    final col = _columnOf(cols, cell.centerX);
    if (col == null) continue;
    if (col.field != 'shares' && col.field != 'cost' && col.field != 'price' &&
        col.field != 'costTotal' &&
        col.field != 'amount') {
      continue;
    }
    if (out.containsKey(col.field)) continue;
    final v = parseAmount(cell.text,
        maxAbs: col.field == 'shares' ? 1e12 : 1e9);
    if (v == null || v <= 0) continue;
    out[col.field] = v;
  }
  return out;
}

_Column? _columnOf(List<_Column> cols, double x) {
  for (final c in cols) {
    if (x >= c.left && x < c.right) return c;
  }
  // 落在最外侧：归给最近的列
  _Column? best;
  var bestD = double.infinity;
  for (final c in cols) {
    final d = (c.centerX - x).abs();
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// 一段 → 一行导入数据（取不到标的线索返回 null）
Future<HoldingImportRow?> _buildRow(
  _Segment seg,
  List<_Column>? cols, {
  required CodeMatcher byCode,
  required NameMatcher byName,
}) async {
  final raw = seg.text;
  final labels = _collectLabelValues(seg);

  // ---- 1. 代码 ----
  String? code = labels['code']?.isNotEmpty == true
      ? parseSecurityCode(labels['code']!.first.value)
      : null;
  code ??= parseSecurityCode(raw);

  // ---- 2. 名称（优先标签值，其次段里最长的中文串）----
  String nameGuess = labels['name']?.isNotEmpty == true
      ? labels['name']!.first.value
      : _longestCjkChunk(raw);

  SecurityRow? hit;
  var cand = <SecurityRow>[];
  if (code != null) hit = await byCode(code);
  if (hit == null && nameGuess.isNotEmpty) {
    cand = await _candidates(nameGuess, byName);
    if (cand.isNotEmpty) {
      final best = _bestCandidate(nameGuess, cand);
      if (best != null) hit = best.row;
      // 名称模糊匹配到的代码比 OCR 猜的更可信
      if (hit != null && (code == null || best!.score >= 1.0)) {
        code = hit.code;
      }
    }
  }
  if (hit == null && code == null) return null; // 完全没线索 → 丢掉

  final r = HoldingImportRow(rawText: raw);
  r.candidates = _rankCandidates(nameGuess, cand);
  if (hit != null) {
    r.code = hit.code;
    r.name = hit.name;
    r.kind = hit.assetKind;
    r.market = hit.market;
    r.matched = true;
  } else {
    r.code = code!;
    if (nameGuess.isNotEmpty) r.name = nameGuess;
    r.weak.add('name');
    r.weak.add('code');
  }
  if (nameGuess.isNotEmpty && hit != null && !_nameLooksSame(nameGuess, hit.name)) {
    // 图上的名字和库里的对不太上：提醒看一眼
    r.weak.add('name');
  }

  // ---- 3. 数值 ----
  var shares = _firstAmount(labels['shares'], min: 0.0001);
  var cost = _firstAmount(labels['cost'], min: 0.0001);
  var price = _firstAmount(labels['price'], min: 0.0001);
  var amount = _firstAmount(labels['amount'], min: 0.01);

  if (cols != null) {
    // 表格模式：也读一下按列定位的数（表头不在这一段里，只能靠列）
    for (final row in seg.rows) {
      final byCol = _numbersIn(row, cols);
      shares ??= byCol['shares'];
      cost ??= byCol['cost'];
      price ??= byCol['price'];
      amount ??= byCol['amount'];
    }
  }

  // ---- 4. 校验与兜底 ----
  //
  // 注意口径：**持仓市值 = 份额 × 现价（净值），不是 × 成本**。
  // 所以只拿现价去校验份额，绝不用市值反推成本 —— 那算出来的是净值，
  // 当成成本会把盈亏算错。成本真缺了才用净值兜底，并且明确标成待核对。
  if (shares != null && price != null && amount != null && shares > 0) {
    final expect = shares * price;
    if (expect > 0 && (expect - amount).abs() / amount > 0.03) {
      // 份额 × 现价 和市值对不上：份额多半认错了
      r.weak.add('shares');
    }
  }
  if (cost == null && price != null) {
    // 图里只有净值没有成本：先拿净值顶上，标出来让人改
    cost = price;
    r.weak.add('costPrice');
  }

  // 「持仓成本」是**总成本**（如 187,812.86），不能直接当单价用：
  // 没单价时用 总成本 ÷ 份额 反推；有单价时顺手校验
  final costTotal = _firstAmount(labels['costTotal'], min: 0.01);
  if (costTotal != null && shares != null && shares > 0) {
    final derived = costTotal / shares;
    if (cost == null) {
      cost = derived;
      r.weak.add('costPrice');
    } else if (cost > 0 && (derived / cost - 1).abs() > 0.03) {
      r.weak.add('costPrice');
    }
  }

  // 几何对位没取到的，直接在整段文字里扫一遍（OCR 把整行合成一个 cell 时靠这个）
  shares ??= _scanTextFor(raw, 'shares');
  cost ??= _scanTextFor(raw, 'cost');
  price ??= _scanTextFor(raw, 'price');
  amount ??= _scanTextFor(raw, 'amount');

  r.shares = shares;
  r.costPrice = cost;
  if (shares == null) r.weak.add('shares');
  if (cost == null) r.weak.add('costPrice');

  // 代码是 OCR 猜的、又查不到库 → 也提醒核对
  if (!r.matched) {
    r.weak.add('code');
  }
  return r;
}

/// 这段文本适不适合当这个字段的值
///
/// 关键：**取到的第一个内容不一定是值**。同一行右边可能先撞上「占比 67.3%」这种
/// 属于别的字段的东西 —— 老写法 break 掉就再也找不到真正的份额了。
bool _valueFits(String field, String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  switch (field) {
    case 'shares':
    case 'cost':
    case 'costTotal':
    case 'price':
    case 'amount':
      final v = parseAmount(t);
      return v != null && v > 0;
    case 'code':
      return parseSecurityCode(t) != null;
    case 'name':
      return RegExp(r'[\u4e00-\u9fa5]{2,}').hasMatch(t) &&
          labelFieldOf(t) == null;
    default:
      return false;
  }
}

/// 段内收集「标签 → 值」
///
/// 取值讲究**几何对位**，否则「持有份额 | 成本单价」并排时，
/// 下一行的两个数会被两个标签都抓到同一个：
/// - 同一行：取标签右边第一个非标签内容；
/// - 下一行：取**横向与标签最接近**的那个（卡片模式常见：标签一行、值一行）。
Map<String, List<_Value>> _collectLabelValues(_Segment seg) {
  final out = <String, List<_Value>>{};
  for (var i = 0; i < seg.rows.length; i++) {
    final row = seg.rows[i];
    for (var j = 0; j < row.length; j++) {
      final cell = row[j];
      final field = labelFieldOf(cell.text);
      if (field == null) continue;

      // (a) 同一行，标签右边第一个"像这个字段的值"的内容
      var gotSameRow = false;
      for (var k = j + 1; k < row.length; k++) {
        final next = row[k];
        if (labelFieldOf(next.text) != null) break;
        final v = next.text.trim();
        if (_valueFits(field, v)) {
          (out[field] ??= []).add(_Value(v, i, weak: false));
          gotSameRow = true;
          break;
        }
      }

      // (b) 标签本身就像 "份额:1234" 这种自带值的
      if (!gotSameRow) {
        final rest = _inlineValue(cell.text, field);
        final inline = rest == null ? null : _extractValue(field, rest);
        if (inline != null && _valueFits(field, inline)) {
          (out[field] ??= []).add(_Value(inline, i, weak: false));
          gotSameRow = true;
        }
      }

      // (c) 下一行里横向最接近、且适合该字段的那个值
      if (!gotSameRow && i + 1 < seg.rows.length) {
        final below = seg.rows[i + 1]
            .where((b) => _valueFits(field, b.text))
            .toList();
        if (below.isNotEmpty) {
          below.sort((a, b) =>
              (a.centerX - cell.centerX).abs().compareTo((b.centerX - cell.centerX).abs()));
          final pick = below.first;
          // 两个值离得差不多近就说不准，标成待核对
          final second = below.length > 1 ? below[1] : null;
          final ambiguous = second != null &&
              ((second.centerX - cell.centerX).abs() -
                      (pick.centerX - cell.centerX).abs())
                      .abs() <
                  12;
          (out[field] ??= []).add(_Value(pick.text.trim(), i + 1, weak: ambiguous));
        }
      }
    }
  }
  return out;
}

/// 标签自带值的写法：`持有份额: 5,021` / `成本单价：3.1459`
///
/// 两个坑都要防：
/// - 短同义词会被长标签包含（`成本` 命中 `成本单价`），所以**长的先试**；
/// - 剩下的部分必须是"像值"的东西，否则 `成本单价` 会被切成值 `单价`。
String? _inlineValue(String text, String field) {
  final labels = [...kFieldLabels[field]!]..sort((a, b) => b.length.compareTo(a.length));
  for (final label in labels) {
    final i = text.indexOf(label);
    if (i < 0) continue;
    final rest = text
        .substring(i + label.length)
        .replaceAll(RegExp(r'^[\s:：=]+'), '')
        .trim();
    if (rest.isEmpty) continue;
    final numericOk = RegExp(r'^[-+]?[\d.]').hasMatch(rest);
    final otherOk = field == 'code'
        ? parseSecurityCode(rest) != null
        : RegExp(r'[\u4e00-\u9fa5A-Za-z]').hasMatch(rest);
    if (!numericOk && !otherOk) continue;
    return rest;
  }
  return null;
}

/// 从"标签后面的原文"里取出这个字段真正要的那个值
///
/// OCR 常把 `份额 30,000 成本 1.8617` 合成一行，份额只要最前面那个数字；
/// 整串交给 parseAmount 会认不出来（于是份额就空了）。
String? _extractValue(String field, String rest) {
  final t = rest.trim();
  if (t.isEmpty) return null;
  switch (field) {
    case 'shares':
    case 'cost':
    case 'costTotal':
    case 'price':
    case 'amount':
      final m = RegExp(r'^[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万|亿|千)?')
          .firstMatch(_fixDigits(t));
      return m?.group(0)?.replaceAll(RegExp(r'\s'), '');
    case 'code':
      return parseSecurityCode(t);
    case 'name':
      final m = RegExp(r'^[\u4e00-\u9fa5A-Za-z0-9（）()]{2,}').firstMatch(t);
      return m?.group(0);
  }
  return null;
}

/// 兜底：直接在整段文字里扫「标签 + 紧跟的数字」
///
/// 有的截图 OCR 会把一整行合成一个 cell（天天基金「持仓详情」就是），
/// 此时按几何对位取不到值 —— 直接在文字流里找最靠谱。
/// 扫 `cost` 之前先把「持仓成本」这类**总成本**标签整体挡住，
/// 否则里面的「成本」二字又会把 187,812.86 匹配成单价。
double? _scanTextFor(String text, String field) {
  if (!const ['shares', 'cost', 'costTotal', 'price', 'amount'].contains(field)) {
    return null;
  }
  var flat = text.replaceAll(RegExp(r'\s'), '');
  if (field == 'cost') {
    for (final l in kFieldLabels['costTotal']!) {
      flat = flat.replaceAll(l, '#' * l.length);
    }
  }
  final labels = [...kFieldLabels[field]!]..sort((a, b) => b.length.compareTo(a.length));
  for (final label in labels) {
    var from = 0;
    while (true) {
      final i = flat.indexOf(label, from);
      if (i < 0) break;
      final rest = flat
          .substring(i + label.length)
          .replaceFirst(RegExp(r'^[:：=(-]+'), '');
      final m = RegExp(r'^[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万|亿|千)?').firstMatch(rest);
      if (m != null) {
        final v = parseAmount(m.group(0)!);
        if (v != null && v > 0) return v;
      }
      from = i + label.length;
    }
  }
  return null;
}


/// 候选按名称相似度排序，最多留 4 个给用户挑
List<SecurityRow> _rankCandidates(String guess, List<SecurityRow> cands) {
  if (cands.isEmpty) return const [];
  final scored = [...cands]
    ..sort((a, b) =>
        nameSimilarity(guess, b.name).compareTo(nameSimilarity(guess, a.name)));
  return scored.take(4).toList();
}

class _Value {
  final String value;
  final int row;
  final bool weak;
  _Value(this.value, this.row, {required this.weak});
}

double? _firstAmount(List<_Value>? list, {required double min}) {
  if (list == null) return null;
  for (final v in list) {
    final a = parseAmount(v.value);
    if (a != null && a >= min) return a;
  }
  return null;
}

String _longestCjkChunk(String text) {
  final chunks = text
      .split(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]+'))
      .where((t) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(t))
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return chunks.isEmpty ? '' : chunks.first;
}

/// 名称模糊匹配：按前缀逐级放宽拿候选，再用相似度打分
Future<List<SecurityRow>> _candidates(String name, NameMatcher byName) async {
  final clean = normalizeText(name);
  final lens = <int>[clean.length, 6, 4, 2].where((n) => n >= 2).toSet().toList()
    ..sort((a, b) => b.compareTo(a));
  final out = <String, SecurityRow>{};
  for (final n in lens) {
    if (n > clean.length) continue;
    final q = clean.substring(0, n);
    final list = await byName(q);
    for (final r in list) {
      out.putIfAbsent(r.code, () => r);
    }
    if (out.length >= 12) break;
  }
  return out.values.toList();
}

class _Scored {
  final SecurityRow row;
  final double score;
  _Scored(this.row, this.score);
}

_Scored? _bestCandidate(String guess, List<SecurityRow> cands) {
  _Scored? best;
  for (final c in cands) {
    final s = nameSimilarity(guess, c.name);
    if (best == null || s > best.score) best = _Scored(c, s);
  }
  // 太低就别硬配了，宁可不填
  return (best != null && best.score >= 0.45) ? best : null;
}

bool _nameLooksSame(String a, String b) =>
    nameSimilarity(a, b) >= 0.8 || normalizeText(a) == normalizeText(b);

/// 名称相似度（0..1）：相等/包含/去后缀，再加二元组 Dice 系数
double nameSimilarity(String a, String b) {
  final x = _stripSuffix(normalizeText(a));
  final y = _stripSuffix(normalizeText(b));
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.contains(y) || y.contains(x)) {
    final short = x.length < y.length ? x.length : y.length;
    final long = x.length < y.length ? y.length : x.length;
    return 0.7 + 0.3 * (short / long);
  }
  return _dice(x, y);
}

/// 去掉 "联接/发起式/A/C/ETF" 这类后缀差异
String _stripSuffix(String s) => s
    .replaceAll(RegExp(r'(联接|链接|发起式|指数基金|指数|基金|ETF|LOF|QDII)'), '')
    .replaceAll(RegExp(r'[A-C]$'), '');

double _dice(String a, String b) {
  if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
  final ga = <String>{};
  for (var i = 0; i + 1 < a.length; i++) {
    ga.add(a.substring(i, i + 2));
  }
  var hit = 0;
  for (var i = 0; i + 1 < b.length; i++) {
    if (ga.contains(b.substring(i, i + 2))) hit++;
  }
  final total = (a.length - 1) + (b.length - 1);
  return total <= 0 ? 0 : 2 * hit / total;
}
