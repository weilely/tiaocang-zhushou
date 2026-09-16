import '../data/nav_models.dart';

/// 参考基准的类型
///
/// 值名不能叫 `index`：那会和枚举自带的静态成员 `index` 撞名。
enum BenchmarkKind { custom, marketIndex }

extension BenchmarkKindX on BenchmarkKind {
  String get label => switch (this) {
        BenchmarkKind.custom => '自定义年化收益率',
        BenchmarkKind.marketIndex => '大盘指数',
      };
}

/// 参考基准
///
/// - `custom`：用户填的年化百分比，按**单利**摊到区间天数（与国内 App 的
///   「参考年化收益」写法一致）
/// - `marketIndex`：真实指数收盘价，按 `close(D)/close(区间首日) − 1` 算区间涨跌
class Benchmark {
  final BenchmarkKind kind;

  /// custom 用：年化百分比
  final double annualPct;

  /// marketIndex 用：`MarketIndex.presets` 里的代码，如 `sh000300`
  final String indexCode;
  final String indexName;

  const Benchmark({
    this.kind = BenchmarkKind.custom,
    this.annualPct = 3.0,
    this.indexCode = 'sh000300',
    this.indexName = '沪深300',
  });

  /// 界面上显示的基准名
  String get label => kind == BenchmarkKind.custom ? '自定义年化' : indexName;

  /// 图例里的一行名，如 `参考收益` / `沪深300`
  String get legendName => kind == BenchmarkKind.custom
      ? '参考收益'
      : (indexName.isEmpty ? indexCode : indexName);

  Benchmark copyWith({
    BenchmarkKind? kind,
    double? annualPct,
    String? indexCode,
    String? indexName,
  }) =>
      Benchmark(
        kind: kind ?? this.kind,
        annualPct: annualPct ?? this.annualPct,
        indexCode: indexCode ?? this.indexCode,
        indexName: indexName ?? this.indexName,
      );

  Map<String, String> toSettings() => {
        'benchmarkKind': kind.name,
        'benchmarkAnnualPct': annualPct.toString(),
        'benchmarkIndexCode': indexCode,
        'benchmarkIndexName': indexName,
      };

  static Benchmark fromSettings(
    String? kind,
    String? annualPct,
    String? code,
    String? name,
  ) {
    final k = kind == BenchmarkKind.marketIndex.name
        ? BenchmarkKind.marketIndex
        : BenchmarkKind.custom;
    final pct = double.tryParse((annualPct ?? '').trim());
    return Benchmark(
      kind: k,
      annualPct: (pct != null && pct.isFinite) ? pct : 3.0,
      indexCode:
          (code == null || code.trim().isEmpty) ? 'sh000300' : code.trim(),
      indexName:
          (name == null || name.trim().isEmpty) ? '沪深300' : name.trim(),
    );
  }
}

const Benchmark kDefaultBenchmark = Benchmark();

/// 基准在 [day] 当天的**区间累计收益率**（%）
///
/// 返回 `null` 表示该日基准无数据（指数还没上市 / 历史拉取失败），
/// 此时界面只画组合单线，不编造基准值。
double? refPctOn({
  required Benchmark benchmark,
  required List<NavPoint> indexNavs,
  required DateTime rangeStart,
  required DateTime day,
}) {
  if (benchmark.kind == BenchmarkKind.custom) {
    final days = _dayOnly(day).difference(_dayOnly(rangeStart)).inDays;
    if (days < 0) return null;
    return benchmark.annualPct * days / 365;
  }

  final startClose = _closeOn(indexNavs, rangeStart);
  final close = _closeOn(indexNavs, day);
  if (startClose == null || close == null || startClose <= 0) return null;
  return (close / startClose - 1) * 100;
}

/// 指数基准曲线的对齐起点：`max(区间起点, 基准首个数据日)`
///
/// 指数历史有长度上限（新浪日K 实测 `datalen=1500` 可用、`2000` 返回空，约 6 年）。
/// 区间比它更早时，两条曲线都从对齐起点开始，才是同区间可比。
DateTime? alignedStart(DateTime rangeStart, List<NavPoint> indexNavs) {
  if (indexNavs.isEmpty) return null;
  final first = DateTime.tryParse(indexNavs.first.date);
  if (first == null) return null;
  final f = _dayOnly(first);
  final s = _dayOnly(rangeStart);
  return f.isAfter(s) ? f : s;
}

/// 指数在 [day] 或之前最近一个交易日的收盘价（前向填充）
double? _closeOn(List<NavPoint> navs, DateTime day) {
  final d = _dayOnly(day);
  double? v;
  for (final p in navs) {
    final pd = DateTime.tryParse(p.date);
    if (pd == null) continue;
    if (_dayOnly(pd).isAfter(d)) break;
    if (p.nav > 0) v = p.nav;
  }
  return v;
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 基准的区间收益（图例里的那个数）
double? refPctOfRange({
  required Benchmark benchmark,
  required List<NavPoint> indexNavs,
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  if (benchmark.kind == BenchmarkKind.custom) {
    final days = _dayOnly(rangeEnd).difference(_dayOnly(rangeStart)).inDays;
    if (days < 0) return null;
    return benchmark.annualPct * days / 365;
  }
  final start = alignedStart(rangeStart, indexNavs) ?? _dayOnly(rangeStart);
  final a = _closeOn(indexNavs, start);
  final b = _closeOn(indexNavs, rangeEnd);
  if (a == null || b == null || a <= 0) return null;
  return (b / a - 1) * 100;
}

/// 基准曲线（与组合曲线逐日对齐）
///
/// 返回与 [dates] 等长的百分比列表，任一点取不到基准值则为 `null`，
/// 组合曲线照旧画点，只是基准线在那一段断开。
List<double?> refSeriesOn({
  required Benchmark benchmark,
  required List<NavPoint> indexNavs,
  required DateTime rangeStart,
  required List<DateTime> dates,
}) {
  if (benchmark.kind == BenchmarkKind.custom) {
    return [
      for (final d in dates)
        refPctOn(
          benchmark: benchmark,
          indexNavs: indexNavs,
          rangeStart: rangeStart,
          day: d,
        ),
    ];
  }

  final start = alignedStart(rangeStart, indexNavs);
  if (start == null) return List<double?>.filled(dates.length, null);
  final a = _closeOn(indexNavs, start);
  if (a == null || a <= 0) return List<double?>.filled(dates.length, null);
  return [
    for (final d in dates)
      () {
        if (_dayOnly(d).isBefore(start)) return null;
        final b = _closeOn(indexNavs, d);
        return b == null ? null : (b / a - 1) * 100;
      }(),
  ];
}
