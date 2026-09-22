import '../data/nav_models.dart';

/// 区间收益的口径
enum ReturnPeriod { w1, m1, m6, y1, y3, y5, inception }

extension ReturnPeriodX on ReturnPeriod {
  String get label => switch (this) {
        ReturnPeriod.w1 => '近1周',
        ReturnPeriod.m1 => '近1月',
        ReturnPeriod.m6 => '近6月',
        ReturnPeriod.y1 => '近1年',
        ReturnPeriod.y3 => '近3年',
        ReturnPeriod.y5 => '近5年',
        ReturnPeriod.inception => '成立以来',
      };

  /// 需要往前推的天数；成立以来为 null
  int? get days => switch (this) {
        ReturnPeriod.w1 => 7,
        ReturnPeriod.m1 => 30,
        ReturnPeriod.m6 => 182,
        ReturnPeriod.y1 => 365,
        ReturnPeriod.y3 => 1095,
        ReturnPeriod.y5 => 1825,
        ReturnPeriod.inception => null,
      };
}

/// 表格里展示的列顺序
const List<ReturnPeriod> tablePeriods = [
  ReturnPeriod.w1,
  ReturnPeriod.m1,
  ReturnPeriod.m6,
  ReturnPeriod.y1,
  ReturnPeriod.y3,
  ReturnPeriod.y5,
  ReturnPeriod.inception,
];

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 计算单个区间收益（%）。
///
/// [points] 需按日期升序。优先用**累计净值**（分红再投资口径，与天天基金一致），
/// 缺失时退回单位净值。历史长度不足该区间时返回 null（界面显示 `--`，而不是 0）。
///
/// 起点日没有记录时，取该日**之前**最近的一个有价日。
double? periodReturn(
  List<NavPoint> points,
  ReturnPeriod period, {
  DateTime? asOf,
}) {
  if (points.length < 2) return null;

  final sorted = List<NavPoint>.from(points)
    ..sort((a, b) => a.date.compareTo(b.date));
  final last = sorted.last;
  final lastValue = last.value;
  if (lastValue <= 0) return null;

  final today = asOf == null
      ? DateTime.parse(last.date)
      : DateTime(asOf.year, asOf.month, asOf.day);
  final span = period.days;

  NavPoint? start;
  if (span == null) {
    start = sorted.first;
  } else {
    final target = _key(today.subtract(Duration(days: span)));
    // 取该日之前（含当天）最近的一条
    for (final p in sorted) {
      if (p.date.compareTo(target) <= 0) {
        start = p;
      } else {
        break;
      }
    }
  }

  if (start == null || identical(start, last)) return null;
  final startValue = start.value;
  if (startValue <= 0) return null;

  // 历史覆盖不足：起点比目标日早太多也不行（说明区间内根本没数据）
  if (span != null) {
    final target = today.subtract(Duration(days: span));
    final earliest = DateTime.parse(sorted.first.date);
    // 目标日早于最早记录 → 该区间没有足够历史
    if (target.isBefore(earliest)) return null;
  }

  return (lastValue / startValue - 1) * 100;
}

/// 一次算完 7 个区间
Map<ReturnPeriod, double?> allPeriodReturns(
  List<NavPoint> points, {
  DateTime? asOf,
}) =>
    {
      for (final p in tablePeriods) p: periodReturn(points, p, asOf: asOf),
    };

/// 涨跌幅文案；null（历史不足）显示 `--`
String formatReturnPct(double? v, {int digits = 2}) {
  if (v == null || v.isNaN || v.isInfinite) return '--';
  final s = v.abs().toStringAsFixed(digits);
  if (v > 0) return '+$s%';
  if (v < 0) return '-$s%';
  return '$s%';
}

/// 最新一条净值（日期 + 值）
///
/// 关注表的净值列要在净值下方显示它的日期，所以这里把整条返回，
/// 避免为了拿日期再排一次序。
NavPoint? latestPoint(List<NavPoint> points) {
  if (points.isEmpty) return null;
  final sorted = List<NavPoint>.from(points)
    ..sort((a, b) => a.date.compareTo(b.date));
  return sorted.last;
}

/// 最新净值
double? latestNav(List<NavPoint> points) => latestPoint(points)?.nav;

/// 「今年以来」累计收益率序列的返回：值（%）+ 序列起始日
typedef YtdSeries = ({List<double> values, String startDate});

/// 「今年以来」的**累计收益率序列**（%）—— 供持仓卡片的迷你曲线用
///
/// 口径与 [periodReturn] 一致：优先**累计净值**（分红再投资，与天天基金一致），
/// 缺失时退回单位净值。基准取**年初（含）之前最近的一条**；如果这只标的是今年
/// 才成立的（年初之前没有数据），基准就是年内第一条，起始日也如实返回 ——
/// 界面据此把标题写成「今年以来」或「MM-DD 以来」，不假装是全年。
/// 点数不足 2 个 → 返回 null（界面**不画**曲线，而不是画一条假的）。
YtdSeries? ytdReturnSeries(
  List<NavPoint> points, {
  DateTime? asOf,
  int? year,
}) {
  if (points.length < 2) return null;
  final sorted = List<NavPoint>.from(points)
    ..sort((a, b) => a.date.compareTo(b.date));

  final y = year ?? (asOf ?? DateTime.now()).year;
  final startKey = _key(DateTime(y, 1, 1));
  final inYear = <NavPoint>[
    for (final p in sorted)
      if (p.date.compareTo(startKey) >= 0 && DateTime.parse(p.date).year == y) p,
  ];
  if (inYear.isEmpty) return null;

  // 基准：年初之前最近的一条（没有就用年内第一条）
  var base = inYear.first;
  for (final p in sorted) {
    if (p.date.compareTo(startKey) < 0) {
      base = p;
    } else {
      break;
    }
  }
  final baseValue = base.value;
  if (baseValue <= 0) return null;

  final values = <double>[(inYear.first.value / baseValue - 1) * 100];
  for (var i = 1; i < inYear.length; i++) {
    final v = inYear[i].value;
    if (v <= 0) continue;
    values.add((v / baseValue - 1) * 100);
  }
  if (values.length < 2) return null;
  return (values: values, startDate: base.date);
}
