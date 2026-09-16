import 'calendar_grid.dart';

/// 统计区间预设：趋势图与资金流共用一套定义，各自只展示其中一部分。
enum RangePreset { month, m3, m6, year, y1, y3, y5, all, custom }

extension RangePresetX on RangePreset {
  String get label => switch (this) {
        RangePreset.month => '当月',
        RangePreset.m3 => '近3月',
        RangePreset.m6 => '近6月',
        RangePreset.year => '今年',
        RangePreset.y1 => '近1年',
        RangePreset.y3 => '近3年',
        RangePreset.y5 => '近5年',
        RangePreset.all => '全部',
        RangePreset.custom => '自定义区间',
      };
}

/// 趋势图主筹码
const List<RangePreset> trendMainPresets = [
  RangePreset.month,
  RangePreset.m3,
  RangePreset.m6,
  RangePreset.year,
  RangePreset.all,
];

/// 趋势图「更多」
///
/// 不含 `all`：它已经作为 `全部` 出现在主筹码里，放两份只会让人以为不是一个东西。
const List<RangePreset> trendMorePresets = [
  RangePreset.y1,
  RangePreset.y3,
  RangePreset.y5,
  RangePreset.custom,
];

/// 资金流主筹码
const List<RangePreset> flowMainPresets = [
  RangePreset.month,
  RangePreset.year,
  RangePreset.all,
];

/// 资金流「更多」
const List<RangePreset> flowMorePresets = [
  RangePreset.m3,
  RangePreset.m6,
  RangePreset.y1,
  RangePreset.y3,
  RangePreset.custom,
];/// 闭区间 [start, end]
class DateRange {
  final DateTime start;
  final DateTime end;

  DateRange(DateTime start, DateTime end)
      : start = _dayOnly(start),
        end = _dayOnly(end);

  /// 区间天数（含首含尾）
  int get days => end.difference(start).inDays + 1;

  /// 区间起始的**前一日**：期初估值的基准日
  DateTime get dayBeforeStart => start.subtract(const Duration(days: 1));

  @override
  String toString() => '$start..$end';

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 按月平移，日号越界时收敛（1 月 31 日 → 2 月 28/29 日）
DateTime shiftMonths(DateTime d, int delta) {
  var y = d.year;
  var m = d.month + delta;
  while (m < 1) {
    m += 12;
    y -= 1;
  }
  while (m > 12) {
    m -= 12;
    y += 1;
  }
  return DateTime(y, m, clampDay(y, m, d.day));
}

/// 按年平移（闰日收敛）
DateTime shiftYears(DateTime d, int delta) {
  final y = d.year + delta;
  return DateTime(y, d.month, clampDay(y, d.month, d.day));
}

/// 把预设解析成闭区间；[earliest] 是建账首日（`全部` 与「更早」的边界）
///
/// 返回 `null` 表示**无从确定区间**（例如选了 `全部` 但一条记录都没有），
/// 调用方应展示空态而不是编一个区间出来。
DateRange? resolvePreset(
  RangePreset preset, {
  required DateTime now,
  DateTime? earliest,
  DateTime? customStart,
  DateTime? customEnd,
}) {
  final today = _dayOnly(now);
  switch (preset) {
    case RangePreset.month:
      return DateRange(DateTime(today.year, today.month, 1), today);
    case RangePreset.year:
      return DateRange(DateTime(today.year, 1, 1), today);
    case RangePreset.m3:
      return DateRange(shiftMonths(today, -3), today);
    case RangePreset.m6:
      return DateRange(shiftMonths(today, -6), today);
    case RangePreset.y1:
      return DateRange(shiftYears(today, -1), today);
    case RangePreset.y3:
      return DateRange(shiftYears(today, -3), today);
    case RangePreset.y5:
      return DateRange(shiftYears(today, -5), today);
    case RangePreset.all:
      if (earliest == null) return null;
      final e = _dayOnly(earliest);
      // 建账首日可能晚于今天（补录了未来日期），此时收敛成单日区间
      return DateRange(e.isAfter(today) ? today : e, today);
    case RangePreset.custom:
      if (customStart == null || customEnd == null) return null;
      final a = _dayOnly(customStart);
      final b = _dayOnly(customEnd);
      return a.isAfter(b) ? DateRange(b, a) : DateRange(a, b);
  }
}

/// 一段行情/流水的「自然」区间的右端：取记录里最晚的一天
///
/// 用于避免「今天没有任何记录」时区间右端空着——例如模拟数据停在
/// 2026-09-11 而系统日期是 09-14，日历与资金流都应当落在 09-11 而不是 09-14。
DateTime? latestRecordDay({
  required Iterable<DateTime> txnDates,
  required Iterable<DateTime> cashDates,
  required Iterable<String> navDates,
}) {
  DateTime? best;
  void take(DateTime d) {
    final v = _dayOnly(d);
    if (best == null || v.isAfter(best!)) best = v;
  }

  for (final d in txnDates) {
    take(d);
  }
  for (final d in cashDates) {
    take(d);
  }
  for (final s in navDates) {
    final d = DateTime.tryParse(s);
    if (d != null) take(d);
  }
  return best;
}
