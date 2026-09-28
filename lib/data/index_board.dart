/// **「低估榜」**：一眼看出哪些指数低估（2026-09-29 用户口径）。
///
/// 用户原话：「**我就想看哪些指数低估**」+「**按 PE 分位升序、低估在前，列里带上股息率**」；
/// 后续又补两点：**扩大成员** + **只看红利/宽基的筛选**。
///
/// 成员分两批（**每行都要标出"分位是谁给的"**）：
/// ①**蛋卷**（`symbol` 非空）：2026-09-29 把中证目录里"股票类+有基金跟踪+境内"的
///   **357 只候选全量扫过**，蛋卷有数据的只有 **35 只**。盲扫约 3.8 秒/只（20+ 分钟），
///   所以内置；之后只刷新这 35 个（并发 4，十几秒）。它同时给 股息率/PE/PB/ROE/PB 分位。
/// ②**中证自算**（`symbol` 为空）：蛋卷没有、但又是主流宽基/红利的那批（2026-09-29 补
///   **9 只**：上证指数/中证A500/科创100/北证50/中证全指/中证A50/红利质量/全指红利质量/
///   红利价值）—— 用中证 `indexCsiDsPe` 的 PE 历史**自己算分位**（一只一次请求，
///   47KB~340KB / 3~14 秒），**只有 PE 与 PE 分位**，没有股息率/PB（如实显示 `--`）。
///   深证系（深证成指/创业板指）这个接口没有数据，所以补不进来。
///
/// ⚠️ **口径必须写清（界面上也写了）**：
/// - **「低估 / 适中 / 高估」按 PE 分位划**（<30% 低估、>70% 高估）——**刻意不用蛋卷的
///   `eva_type`**：实测它偶尔与分位冲突（500SNLV 分位 0.398 却标 high）。
/// - **两个源的窗口不同**：蛋卷约 10 年（`begin_at`），中证自算是"人家给的全段历史"
///   （2011 起或上市起）。实测同一天：科创50 自算 0.708 / 蛋卷 0.790；证券公司
///   自算 0.022 / 蛋卷 0.000 —— 方向一致、数值有差，**别混成一个数**。
/// - **股息率高 ≠ 低估**：实测 中证红利 股息率 4.26% 但 PE 分位 **79%**、上证红利 97%；
///   反而消费红利 股息率 4.62% 而分位 **8.2%**。所以榜按**分位**排，股息率只作参考。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'csi_pe_hist.dart';

/// PE 分位低于它 = 低估
const double kUndervaluedBelow = 0.30;

/// PE 分位高于它 = 高估
const double kOvervaluedAbove = 0.70;

/// 筛选用的三档（'全部' 不入列表，界面自己加）
const List<String> kBoardKinds = ['宽基', '红利', '行业主题'];

/// 榜单成员。`symbol` 空 = **中证自算**（无蛋卷数据）；非空 = 蛋卷符号。
const List<({String symbol, String code, String name, String kind})>
    kIndexBoardSeeds = [
  // ── 宽基（18）──────────────────────────────────────────────────────────
  (symbol: 'SH000016', code: '000016', name: '上证50', kind: '宽基'),
  (symbol: 'SH000010', code: '000010', name: '上证180', kind: '宽基'),
  (symbol: 'SH000300', code: '000300', name: '沪深300', kind: '宽基'),
  (symbol: 'SH000905', code: '000905', name: '中证500', kind: '宽基'),
  (symbol: 'SH000852', code: '000852', name: '中证1000', kind: '宽基'),
  (symbol: 'SH000903', code: '000903', name: '中证A100', kind: '宽基'),
  (symbol: 'SH000925', code: '000925', name: '基本面50', kind: '宽基'),
  (symbol: 'SH000919', code: '000919', name: '300价值', kind: '宽基'),
  (symbol: 'SZ399701', code: '399701', name: '深证F60', kind: '宽基'),
  (symbol: 'SZ399702', code: '399702', name: '深证F120', kind: '宽基'),
  (symbol: 'CSI930782', code: '930782', name: '500SNLV', kind: '宽基'),
  (symbol: 'CSI931142', code: '931142', name: '东证竞争', kind: '宽基'),
  (symbol: '', code: '000001', name: '上证指数', kind: '宽基'),
  (symbol: '', code: '000510', name: '中证A500', kind: '宽基'),
  (symbol: '', code: '000698', name: '科创100', kind: '宽基'),
  (symbol: '', code: '899050', name: '北证50', kind: '宽基'),
  (symbol: '', code: '000985', name: '中证全指', kind: '宽基'),
  (symbol: '', code: '930050', name: '中证A50', kind: '宽基'),
  // ── 红利（8）───────────────────────────────────────────────────────────
  (symbol: 'CSIH30094', code: 'H30094', name: '消费红利', kind: '红利'),
  (symbol: 'SH000922', code: '000922', name: '中证红利', kind: '红利'),
  (symbol: 'CSIH30269', code: 'H30269', name: '红利低波', kind: '红利'),
  (symbol: 'CSI930740', code: '930740', name: '300红利低波', kind: '红利'),
  (symbol: 'SH000015', code: '000015', name: '红利指数', kind: '红利'),
  (symbol: '', code: '931468', name: '红利质量', kind: '红利'),
  (symbol: '', code: '932315', name: '全指红利质量', kind: '红利'),
  (symbol: '', code: 'H30270', name: '红利价值', kind: '红利'),
  // ── 行业主题（18）──────────────────────────────────────────────────────
  (symbol: 'SZ399975', code: '399975', name: '证券公司', kind: '行业主题'),
  (symbol: 'SZ399812', code: '399812', name: '养老产业', kind: '行业主题'),
  (symbol: 'SZ399997', code: '399997', name: '中证白酒', kind: '行业主题'),
  (symbol: 'SH000932', code: '000932', name: '800消费', kind: '行业主题'),
  (symbol: 'SH000989', code: '000989', name: '全指可选', kind: '行业主题'),
  (symbol: 'SZ399989', code: '399989', name: '中证医疗', kind: '行业主题'),
  (symbol: 'SZ399971', code: '399971', name: '中证传媒', kind: '行业主题'),
  (symbol: 'SH000991', code: '000991', name: '全指医药', kind: '行业主题'),
  (symbol: 'SZ399967', code: '399967', name: '中证军工', kind: '行业主题'),
  (symbol: 'SH000978', code: '000978', name: '医药100', kind: '行业主题'),
  (symbol: 'SH000827', code: '000827', name: '中证环保', kind: '行业主题'),
  (symbol: 'SH000993', code: '000993', name: '全指信息', kind: '行业主题'),
  (symbol: 'CSI931087', code: '931087', name: '科技龙头', kind: '行业主题'),
  (symbol: 'CSI930652', code: '930652', name: 'CS电子', kind: '行业主题'),
  (symbol: 'CSI931079', code: '931079', name: '5G通信', kind: '行业主题'),
  (symbol: 'SH000688', code: '000688', name: '科创50', kind: '行业主题'),
  (symbol: 'SZ399998', code: '399998', name: '中证煤炭', kind: '行业主题'),
  (symbol: 'SZ399986', code: '399986', name: '中证银行', kind: '行业主题'),
];

/// 蛋卷那一批（有 symbol 的）有多少只
int get kBoardDanjuanCount =>
    kIndexBoardSeeds.where((e) => e.symbol.isNotEmpty).length;

/// 需要中证自算分位的那批有多少只
int get kBoardComputedCount =>
    kIndexBoardSeeds.where((e) => e.symbol.isEmpty).length;

/// 榜单排序字段
enum BoardSort {
  pePercentile('PE 分位'),
  pbPercentile('PB 分位'),
  dividend('股息率'),
  pe('PE'),
  name('名称');

  const BoardSort(this.label);
  final String label;

  /// 这个字段"有意思"的方向：分位/PE 从小到大（低估在前），股息率从大到小
  bool get defaultDesc => this == BoardSort.dividend;
}

/// 榜单里的一行（两个源的字段合成一条，**`source` 标明分位是谁给的**）
class IndexBoardEntry {
  final String code;
  final String name;

  /// 宽基 / 红利 / 行业主题
  final String kind;

  /// 蛋卷符号（空 = 中证自算）
  final String symbol;

  /// 这次取到数据了吗（false = 如实说"这次没取到"，**不是 0**）
  final bool ok;

  final double? pe;
  final double? pb;
  final double? roe;
  final double? dividend;
  final double? pePct;
  final double? pbPct;

  /// 数据日期（蛋卷 `09-28` / 自算 `yyyyMMdd`，各自原样）
  final String date;

  /// 自算时的窗口起点（`yyyyMMdd`）与样本数
  final String windowStart;
  final int samples;

  const IndexBoardEntry({
    required this.code,
    required this.name,
    this.kind = '',
    this.symbol = '',
    this.ok = false,
    this.pe,
    this.pb,
    this.roe,
    this.dividend,
    this.pePct,
    this.pbPct,
    this.date = '',
    this.windowStart = '',
    this.samples = 0,
  });

  /// 分位是谁给的
  String get source => symbol.isEmpty ? '中证自算' : '蛋卷';

  /// 没取到这次的数据
  bool get missing => !ok;

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
        'code': code,
        'name': name,
        'kind': kind,
        'symbol': symbol,
        'ok': ok,
        'pe': pe,
        'pb': pb,
        'roe': roe,
        'yeild': dividend,
        'pePct': pePct,
        'pbPct': pbPct,
        'date': date,
        'from': windowStart,
        'n': samples,
      };

  static IndexBoardEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = '${json['code'] ?? ''}'.trim();
    final name = '${json['name'] ?? ''}'.trim();
    if (code.isEmpty || name.isEmpty) return null;
    // 注意别把局部函数命名成 num（会遮住 num 类型，编译不过）
    double? toD(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());
    return IndexBoardEntry(
      code: code,
      name: name,
      kind: '${json['kind'] ?? ''}',
      symbol: '${json['symbol'] ?? ''}',
      ok: json['ok'] == true,
      pe: toD(json['pe']),
      pb: toD(json['pb']),
      roe: toD(json['roe']),
      dividend: toD(json['yeild']),
      pePct: toD(json['pePct']),
      pbPct: toD(json['pbPct']),
      date: '${json['date'] ?? ''}',
      windowStart: '${json['from'] ?? ''}',
      samples: toD(json['n'])?.toInt() ?? 0,
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
///
/// 两个时间戳分开存：蛋卷那批便宜（12 小时一刷），**中证自算那批贵**（一只 3~14 秒、
/// 几十 KB~几百 KB），所以**一个月才重算一次**。
class IndexBoardStore {
  final Future<Directory> Function() _dirOf;

  /// 缓存结构版本：**改了行的字段就 +1** —— 否则老缓存会被新解析读成"全都没取到"，
  /// 而且因为时间戳还算新鲜、12 小时都不会重刷（这次就踩了：老版存的是嵌套 `v`）。
  static const int cacheVersion = 2;

  IndexBoardStore({Future<Directory> Function()? dirOf})
      : _dirOf = dirOf ?? getApplicationSupportDirectory;

  Future<File> _file() async =>
      File(p.join((await _dirOf()).path, 'index_board.json'));

  Future<void> save(
    List<IndexBoardEntry> rows, {
    required DateTime danjuanAt,
    required DateTime computedAt,
  }) async {
    try {
      final dir = await _dirOf();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await (await _file()).writeAsString(jsonEncode({
        'v': cacheVersion,
        'danjuanAt': danjuanAt.toIso8601String(),
        'computedAt': computedAt.toIso8601String(),
        'rows': [for (final r in rows) r.toJson()],
      }));
    } catch (_) {
      // 缓存写不进去不影响本次使用
    }
  }

  /// 读缓存；没有/坏了/**版本对不上**都返回 null（**不抛**）
  Future<(List<IndexBoardEntry>, DateTime, DateTime)?> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      if (j['v'] != cacheVersion) return null; // 老结构 → 当作没缓存，重刷
      final at = DateTime.tryParse('${j['danjuanAt']}') ?? DateTime.now();
      final csiAt = DateTime.tryParse('${j['computedAt']}') ?? at;
      final raw = j['rows'];
      if (raw is! List) return null;
      final rows = <IndexBoardEntry>[];
      for (final r in raw) {
        final e = IndexBoardEntry.fromJson(r);
        if (e != null) rows.add(e);
      }
      if (rows.isEmpty) return null;
      return (rows, at, csiAt);
    } catch (_) {
      return null;
    }
  }
}

/// 把 `CsiPeStat` 装成榜单行（自算那批）
IndexBoardEntry entryFromPeStat(
  ({String symbol, String code, String name, String kind}) seed,
  CsiPeStat? stat,
) {
  if (stat == null) {
    return IndexBoardEntry(code: seed.code, name: seed.name, kind: seed.kind);
  }
  return IndexBoardEntry(
    code: seed.code,
    name: seed.name,
    kind: seed.kind,
    ok: true,
    pe: stat.pe,
    pePct: stat.percentile,
    date: stat.date,
    windowStart: stat.windowStart,
    samples: stat.samples,
  );
}
