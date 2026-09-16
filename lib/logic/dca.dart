import '../data/dca_models.dart';

/// `yyyy-MM-dd`，用作「日期 → 价格」表的键
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 生成 `[start, until]` 区间内所有应投日期（升序）。
///
/// - `monthly`：每月 `dayOfPeriod` 号（1–28，超出月份天数时钳制到月末）
/// - `weekly`：从 start 起第一个星期几等于 `dayOfPeriod`（1=周一…7=周日）的日子，然后每 7 天
/// - `biweekly`：start 起每 14 天
List<DateTime> dcaPeriods({
  required DateTime start,
  required DcaFrequency frequency,
  required int dayOfPeriod,
  required DateTime until,
  int hardLimit = 600,
}) {
  final s = dayOnly(start);
  final u = dayOnly(until);
  if (u.isBefore(s)) return const [];

  final out = <DateTime>[];

  switch (frequency) {
    case DcaFrequency.monthly:
      var y = s.year;
      var m = s.month;
      for (var i = 0; i < hardLimit; i++) {
        final lastDay = DateTime(y, m + 1, 0).day;
        final d = DateTime(y, m, dayOfPeriod.clamp(1, lastDay));
        if (d.isAfter(u)) break;
        if (!d.isBefore(s)) out.add(d);
        m++;
        if (m > 12) {
          m = 1;
          y++;
        }
      }
      break;

    case DcaFrequency.weekly:
      var d = s;
      final target = dayOfPeriod.clamp(1, 7);
      var shift = 0;
      while (d.weekday != target && shift < 7) {
        d = d.add(const Duration(days: 1));
        shift++;
      }
      for (var i = 0; i < hardLimit && !d.isAfter(u); i++) {
        out.add(d);
        d = d.add(const Duration(days: 7));
      }
      break;

    case DcaFrequency.biweekly:
      var d = s;
      for (var i = 0; i < hardLimit && !d.isAfter(u); i++) {
        out.add(d);
        d = d.add(const Duration(days: 14));
      }
      break;
  }

  return out;
}

/// 从 `lastRunDate` 之后到 `today` 的待补记日期。
///
/// 超过 [maxNew] 期时只取**最近**的 [maxNew] 期（避免首次启用就补出上百笔）。
List<DateTime> pendingDcaDates({
  required DcaPlan plan,
  required DateTime today,
  int maxNew = 24,
}) {
  final all = dcaPeriods(
    start: plan.startDate,
    frequency: plan.frequency,
    dayOfPeriod: plan.dayOfPeriod,
    until: today,
  );
  final last = plan.lastRunDate;
  final pending =
      last == null ? all : all.where((d) => d.isAfter(dayOnly(last))).toList();
  if (pending.length <= maxNew) return pending;
  return pending.sublist(pending.length - maxNew);
}

/// 一期定投实际使用的成交日与价格
class DcaPriceRef {
  final DateTime date;
  final double price;
  const DcaPriceRef(this.date, this.price);
}

/// 给定应投日，从「日期 → 价格」表里定出实际成交日与价格。
///
/// 规则：**当天有价用当天；否则顺延到 `due` 之后、不超过 `today` 的第一个有价日。**
/// 找不到就返回 null —— 调用方应当**跳过该期且不推进断点**，下次再试。
/// 刻意不向前回退取价：那等于用定投日之前的净值成交，是错的。
DcaPriceRef? resolveDcaPrice({
  required DateTime due,
  required DateTime today,
  required Map<String, double> priceByDay,
}) {
  final d0 = dayOnly(due);
  final t = dayOnly(today);

  final exact = priceByDay[dayKey(d0)];
  if (exact != null && exact > 0) return DcaPriceRef(d0, exact);

  var d = d0.add(const Duration(days: 1));
  while (!d.isAfter(t)) {
    final p = priceByDay[dayKey(d)];
    if (p != null && p > 0) return DcaPriceRef(d, p);
    d = d.add(const Duration(days: 1));
  }
  return null;
}

/// 计划的下一次扣款日（用于 UI 展示）。已停止或已到期返回 null。
DateTime? nextDcaDate(DcaPlan plan, DateTime today) {
  final t = dayOnly(today);
  // 从今天开始往后找第一个应投日
  final future = dcaPeriods(
    start: t,
    frequency: plan.frequency,
    dayOfPeriod: plan.dayOfPeriod,
    until: DateTime(t.year + 1, t.month, t.day),
  );
  if (future.isEmpty) return null;
  return future.first;
}
