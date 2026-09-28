/// **「低估榜」**：一眼看出哪些指数低估（2026-09-29 用户口径）。
///
/// 用户原话：「**我就想看哪些指数低估**」+「**按 PE 分位升序、低估在前，列里带上股息率**」。
///
/// 数据分工：
/// - **估值与分位**：蛋卷 `index_eva/detail/<符号>`（它同时给 股息率/PE/PB/ROE +
///   PE/PB 历史分位 —— 这是判"低估"的关键）
/// - **成员**：内置 [kIndexBoardSeeds] —— 2026-09-29 把中证目录里"股票类+有基金跟踪+
///   境内"的 **357 只候选全量扫过**，蛋卷有数据的只有 **35 只**。**盲扫约 3.8 秒/只
///   （20+ 分钟）**，所以内置；之后进页面只刷新这 35 个的数值（可并发，十几秒），
///   未收录的那 322 只不再重试。
///
/// ⚠️ **口径必须写清（界面上也写了）**：
/// - **「低估 / 适中 / 高估」是按 PE 分位划的**（<30% 低估、>70% 高估）——
///   **刻意不用蛋卷自己的 `eva_type`**：实测它偶尔与分位冲突（500SNLV 分位 0.398
///   却标 high），摆两个互相矛盾的口径只会让人更糊涂。
/// - **股息率高 ≠ 低估**：实测 中证红利 股息率 4.26% 但 PE 分位 **79%**、
///   上证红利 分位 **97%**；反而消费红利 股息率 4.62% 而分位 **8.2%**。
///   所以榜按**分位**排，股息率只作一列参考。
/// - 分位的窗口由蛋卷给（`begin_at` 起，约 10 年），页面标注数据日期。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'index_eva.dart';

/// PE 分位低于它 = 低估
const double kUndervaluedBelow = 0.30;

/// PE 分位高于它 = 高估
const double kOvervaluedAbove = 0.70;

/// 榜单成员（2026-09-29 全量扫描 357 只候选得到的那 35 只有数据的）
const List<({String symbol, String code, String name})> kIndexBoardSeeds = [
  (symbol: 'SZ399975', code: '399975', name: '证券公司'),
  (symbol: 'SZ399812', code: '399812', name: '养老产业'),
  (symbol: 'CSIH30094', code: 'H30094', name: '消费红利'),
  (symbol: 'SZ399997', code: '399997', name: '中证白酒'),
  (symbol: 'SH000932', code: '000932', name: '800消费'),
  (symbol: 'SH000989', code: '000989', name: '全指可选'),
  (symbol: 'SZ399989', code: '399989', name: '中证医疗'),
  (symbol: 'SZ399971', code: '399971', name: '中证传媒'),
  (symbol: 'SH000991', code: '000991', name: '全指医药'),
  (symbol: 'SZ399967', code: '399967', name: '中证军工'),
  (symbol: 'SH000978', code: '000978', name: '医药100'),
  (symbol: 'CSI930782', code: '930782', name: '500SNLV'),
  (symbol: 'SH000827', code: '000827', name: '中证环保'),
  (symbol: 'SH000993', code: '000993', name: '全指信息'),
  (symbol: 'SH000925', code: '000925', name: '基本面50'),
  (symbol: 'SZ399701', code: '399701', name: '深证F60'),
  (symbol: 'SH000016', code: '000016', name: '上证50'),
  (symbol: 'SH000010', code: '000010', name: '上证180'),
  (symbol: 'SH000300', code: '000300', name: '沪深300'),
  (symbol: 'CSI931087', code: '931087', name: '科技龙头'),
  (symbol: 'SH000919', code: '000919', name: '300价值'),
  (symbol: 'SH000852', code: '000852', name: '中证1000'),
  (symbol: 'CSI930652', code: '930652', name: 'CS电子'),
  (symbol: 'SH000905', code: '000905', name: '中证500'),
  (symbol: 'SZ399702', code: '399702', name: '深证F120'),
  (symbol: 'CSI931079', code: '931079', name: '5G通信'),
  (symbol: 'CSIH30269', code: 'H30269', name: '红利低波'),
  (symbol: 'SH000688', code: '000688', name: '科创50'),
  (symbol: 'SH000922', code: '000922', name: '中证红利'),
  (symbol: 'CSI930740', code: '930740', name: '300红利低波'),
  (symbol: 'CSI931142', code: '931142', name: '东证竞争'),
  (symbol: 'SZ399998', code: '399998', name: '中证煤炭'),
  (symbol: 'SH000903', code: '000903', name: '中证A100'),
  (symbol: 'SZ399986', code: '399986', name: '中证银行'),
  (symbol: 'SH000015', code: '000015', name: '红利指数'),
];

/// 榜单排序字段
enum BoardSort {
  pePercentile('PE 分位'),
  pbPercentile('PB 分位'),
  dividend('股息率'),
  pe('PE'),
  name('名称');

  const BoardSort(this.label);
  final String label;

  /// 这个字段的"有意思"的方向：分位/PE 从小到大（低估在前），股息率从大到小
  bool get defaultDesc => this == BoardSort.dividend;
}

/// 榜单里的一行
class IndexBoardEntry {
  final String symbol;
  final String code;
  final String name;

  /// 取到的估值（null = 这次没取到，**不代表没有数据**）
  final IndexValuation? v;

  const IndexBoardEntry({
    required this.symbol,
    required this.code,
    required this.name,
    this.v,
  });

  double? get dividend => v?.yeild;
  double? get pe => v?.pe;
  double? get pb => v?.pb;
  double? get roe => v?.roe;
  double? get pePct => v?.pePercentile;
  double? get pbPct => v?.pbPercentile;
  String get date => v?.date ?? '';

  /// 没取到这次的数据（网络失败等）—— 界面要如实说，别显示成 0
  bool get missing => v == null;

  double? numOf(BoardSort s) => switch (s) {
        BoardSort.pePercentile => pePct,
        BoardSort.pbPercentile => pbPct,
        BoardSort.dividend => dividend,
        BoardSort.pe => pe,
        BoardSort.name => null,
      };

  /// **低估 / 适中 / 高估**（按 PE 分位；没有分位就没有标签）
  String get zone {
    final p = pePct;
    if (p == null) return '';
    if (p < kUndervaluedBelow) return '低估';
    if (p > kOvervaluedAbove) return '高估';
    return '适中';
  }

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'code': code,
        'name': name,
        if (v != null) 'v': v!.toJson(),
      };

  static IndexBoardEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final symbol = '${json['symbol'] ?? ''}'.trim();
    final code = '${json['code'] ?? ''}'.trim();
    final name = '${json['name'] ?? ''}'.trim();
    if (symbol.isEmpty || name.isEmpty) return null;
    final raw = json['v'];
    return IndexBoardEntry(
      symbol: symbol,
      code: code,
      name: name,
      v: raw is Map
          ? IndexValuation.fromJson(symbol, {'data': raw})
          : null,
    );
  }
}

/// 排序（**缺值的永远沉底**，哪个方向都一样）
List<IndexBoardEntry> sortBoard(
  List<IndexBoardEntry> rows,
  BoardSort sort, {
  bool? desc,
}) {
  final d = desc ?? sort.defaultDesc;
  final list = List.of(rows);
  list.sort((a, b) {
    if (sort == BoardSort.name) {
      final r = a.name.compareTo(b.name);
      return d ? -r : r;
    }
    final x = a.numOf(sort);
    final y = b.numOf(sort);
    if (x == null && y == null) return a.code.compareTo(b.code);
    if (x == null) return 1; // 缺值沉底，不受方向影响
    if (y == null) return -1;
    final r = x.compareTo(y);
    if (r == 0) return a.code.compareTo(b.code);
    return d ? -r : r;
  });
  return list;
}

/// 榜单快照的落盘缓存（`index_board.json`，应用私有目录；**不建库表、不动 DB 版本**）
class IndexBoardStore {
  final Future<Directory> Function() _dirOf;

  IndexBoardStore({Future<Directory> Function()? dirOf})
      : _dirOf = dirOf ?? getApplicationSupportDirectory;

  Future<File> _file() async => File(p.join((await _dirOf()).path, 'index_board.json'));

  Future<void> save(List<IndexBoardEntry> rows, DateTime at) async {
    try {
      final dir = await _dirOf();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await (await _file()).writeAsString(jsonEncode({
        'fetchedAt': at.toIso8601String(),
        'rows': [for (final r in rows) r.toJson()],
      }));
    } catch (_) {
      // 缓存写不进去不影响本次使用
    }
  }

  /// 读缓存；没有/坏了返回 null（**不抛**）
  Future<(List<IndexBoardEntry>, DateTime)?> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final at = DateTime.tryParse('${j['fetchedAt']}') ?? DateTime.now();
      final raw = j['rows'];
      if (raw is! List) return null;
      final rows = <IndexBoardEntry>[];
      for (final r in raw) {
        final e = IndexBoardEntry.fromJson(r);
        if (e != null) rows.add(e);
      }
      if (rows.isEmpty) return null;
      return (rows, at);
    } catch (_) {
      return null;
    }
  }
}
