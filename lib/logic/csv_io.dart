import '../data/models.dart';
import 'portfolio.dart';

// ---------------- CSV 基础编解码（RFC 4180，自实现避免依赖变更风险） ----------------

String _csvField(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

/// 编码为 CSV 文本（CRLF 换行，兼容 Excel）
String encodeCsv(List<List<String>> rows) =>
    rows.map((r) => r.map(_csvField).join(',')).join('\r\n');

/// 解析 CSV 文本，支持引号包裹、转义引号、CR/LF/CRLF 换行与 BOM
List<List<String>> decodeCsv(String content) {
  final rows = <List<String>>[];
  var row = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  var i = 0;

  if (content.startsWith('\uFEFF')) i = 1;

  for (; i < content.length; i++) {
    final ch = content[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < content.length && content[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(buf.toString());
      buf.clear();
    } else if (ch == '\n') {
      row.add(buf.toString());
      buf.clear();
      rows.add(row);
      row = <String>[];
    } else if (ch == '\r') {
      // 忽略，由 \n 结束该行
    } else {
      buf.write(ch);
    }
  }

  if (buf.isNotEmpty || row.isNotEmpty) {
    row.add(buf.toString());
    rows.add(row);
  }
  return rows;
}

// ---------------- 交易流水 CSV ----------------

const List<String> txnCsvHeader = [
  '账户',
  '标的类型',
  '代码',
  '名称',
  '交易类型',
  '日期',
  '份额',
  '价格',
  '金额',
  '手续费',
  '备注',
];

const List<String> positionCsvHeader = [
  '账户',
  '代码',
  '名称',
  '类型',
  '份额',
  '成本单价',
  '现价',
  '行情日期',
  '持仓成本',
  '市值',
  '持仓收益',
  '持仓收益率%',
  '已实现收益',
  '累计收益',
  '累计收益率%',
  '当日收益',
  '当日收益类型',
  '年化收益率%',
];

String exportTxnsCsv(
  List<Txn> txns,
  Map<int, Account> accounts,
  Map<int, Asset> assets,
) {
  final rows = <List<String>>[txnCsvHeader];
  final sorted = List<Txn>.from(txns)..sort((a, b) => a.date.compareTo(b.date));
  for (final t in sorted) {
    final a = assets[t.assetId];
    rows.add([
      accounts[t.accountId]?.name ?? '',
      a?.kind.label ?? '',
      a?.code ?? '',
      a?.name ?? '',
      t.type.label,
      _dateStr(t.date),
      _numStr(t.shares),
      _numStr(t.price),
      _numStr(t.amount),
      _numStr(t.fee),
      t.note,
    ]);
  }
  return encodeCsv(rows);
}

String exportPositionsCsv(List<Position> positions, Map<int, Account> accounts) {
  final rows = <List<String>>[positionCsvHeader];
  for (final p in positions) {
    if (p.isEmpty) continue;
    final x = p.xirrPct;
    rows.add([
      accounts[p.accountId]?.name ?? '',
      p.asset.code,
      p.asset.name,
      p.asset.kind.label,
      _numStr(p.shares),
      _numStr(p.avgCost),
      _numStr(p.price),
      p.quote?.infoDate ?? '',
      _numStr(p.cost),
      _numStr(p.marketValue),
      _numStr(p.holdingPnl),
      p.floatingPctOrNull == null ? '' : _numStr(p.floatingPctOrNull!),
      _numStr(p.realized),
      _numStr(p.cumulativePnl),
      _numStr(p.cumulativePct),
      _numStr(p.dayPnl),
      p.hasQuote ? p.dayPnlLabel : '',
      x.isNaN ? '' : _numStr(x),
    ]);
  }
  return encodeCsv(rows);
}

// ---------------- CSV 解析（导入） ----------------

class ParsedTxnRow {
  final String accountName;
  final AssetKind kind;
  final String code;
  final String assetName;
  final TxnType type;
  final DateTime date;
  final double shares;
  final double price;
  final double amount;
  final double fee;
  final String note;

  const ParsedTxnRow({
    required this.accountName,
    required this.kind,
    required this.code,
    required this.assetName,
    required this.type,
    required this.date,
    required this.shares,
    required this.price,
    required this.amount,
    required this.fee,
    required this.note,
  });
}

class CsvParseResult {
  final List<ParsedTxnRow> rows;
  final List<String> errors;
  const CsvParseResult({required this.rows, required this.errors});
}

/// 解析交易流水 CSV。表头需与导出格式一致（交易类型/标的类型也接受英文枚举名）。
CsvParseResult parseTxnCsv(String content) {
  final rows = <ParsedTxnRow>[];
  final errors = <String>[];

  if (content.trim().isEmpty) {
    return const CsvParseResult(rows: [], errors: ['文件内容为空']);
  }

  final table = decodeCsv(content);
  if (table.length < 2) {
    return const CsvParseResult(rows: [], errors: ['没有数据行']);
  }

  final header = table.first.map((e) => e.trim()).toList();
  int idx(String name, {required int fallback}) {
    final i = header.indexOf(name);
    return i >= 0 ? i : fallback;
  }

  final iAccount = idx('账户', fallback: 0);
  final iKind = idx('标的类型', fallback: 1);
  final iName = idx('名称', fallback: 3);
  final iType = idx('交易类型', fallback: 4);
  final iDate = idx('日期', fallback: 5);
  final iShares = idx('份额', fallback: 6);
  final iPrice = idx('价格', fallback: 7);
  final iAmount = idx('金额', fallback: 8);
  final iFee = idx('手续费', fallback: 9);
  final iNote = idx('备注', fallback: 10);

  if (!header.contains('代码') ||
      !header.contains('交易类型') ||
      !header.contains('日期')) {
    return const CsvParseResult(
      rows: [],
      errors: ['表头缺少必要列（代码 / 交易类型 / 日期），请使用本应用导出的 CSV 作为模板'],
    );
  }

  final iCode = header.indexOf('代码');

  String cell(List<String> r, int i) => (i >= 0 && i < r.length) ? r[i].trim() : '';

  for (var r = 1; r < table.length; r++) {
    final row = table[r];
    if (row.every((e) => e.trim().isEmpty)) continue;

    final code = cell(row, iCode);
    if (code.isEmpty) {
      errors.add('第 ${r + 1} 行：代码为空，已跳过');
      continue;
    }

    final type = _parseTxnType(cell(row, iType));
    if (type == null) {
      errors.add('第 ${r + 1} 行：无法识别的交易类型「${cell(row, iType)}」，已跳过');
      continue;
    }

    final date = _parseDate(cell(row, iDate));
    if (date == null) {
      errors.add('第 ${r + 1} 行：无法识别的日期「${cell(row, iDate)}」，已跳过');
      continue;
    }

    final shares = _parseNum(cell(row, iShares));
    final price = _parseNum(cell(row, iPrice));
    var amount = _parseNum(cell(row, iAmount));
    if (amount == 0 && shares != 0 && price != 0) amount = shares * price;

    rows.add(ParsedTxnRow(
      accountName: cell(row, iAccount),
      kind: _parseKind(cell(row, iKind), code),
      code: code,
      assetName: cell(row, iName),
      type: type,
      date: date,
      shares: shares,
      price: price,
      amount: amount,
      fee: _parseNum(cell(row, iFee)),
      note: cell(row, iNote),
    ));
  }

  return CsvParseResult(rows: rows, errors: errors);
}

AssetKind _parseKind(String raw, String code) {
  final s = raw.trim();
  for (final k in AssetKind.values) {
    if (s == k.name || s == k.label) return k;
  }
  if (code.length == 6 && (code.startsWith('5') || code.startsWith('1'))) {
    return AssetKind.etf;
  }
  if (code.length == 6 &&
      (code.startsWith('6') || code.startsWith('0') || code.startsWith('3'))) {
    return AssetKind.stock;
  }
  return AssetKind.fund;
}

TxnType? _parseTxnType(String raw) {
  final s = raw.trim();
  for (final t in TxnType.values) {
    if (s == t.name || s == t.label) return t;
  }
  final lower = s.toLowerCase();
  if (s.contains('买') || lower == 'buy') return TxnType.buy;
  if (s.contains('卖') || lower == 'sell') return TxnType.sell;
  if (s.contains('分红') || s.contains('红利') || s.contains('股息')) {
    return TxnType.dividend;
  }
  return null;
}

DateTime? _parseDate(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s.replaceAll('/', '-').replaceAll('.', '-');
  if (RegExp(r'^\d{8}$').hasMatch(s)) {
    s = '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}';
  }
  if (s.length > 10) s = s.substring(0, 10);
  final d = DateTime.tryParse(s);
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day);
}

double _parseNum(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return 0;
  s = s.replaceAll(',', '').replaceAll('%', '').replaceAll('¥', '').replaceAll('￥', '');
  return double.tryParse(s) ?? 0;
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _numStr(double v) {
  if (v == 0 || v.isNaN || v.isInfinite) return '';
  var s = v.toStringAsFixed(6);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}
