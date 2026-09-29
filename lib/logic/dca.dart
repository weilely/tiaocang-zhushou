import '../data/dca_models.dart';
import '../data/models.dart';

/// `yyyy-MM-dd`，用作「日期 → 价格」表的键
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 生成 `[start, until]` 区间内所有应投日期（升序）。
///
/// - `daily`：每天一期（用户 2026-09-29 新增；**非交易日的期数会被
///   [resolveDcaPrice] 顺延到之后第一个交易日**，所以这里的"每天"就是日历日）
/// - `monthly`：每月 `dayOfPeriod` 号（1–28，超出月份天数时钳制到月末）
/// - `weekly`：从 start 起第一个星期几等于 `dayOfPeriod`（1=周一…7=周日）的日子，然后每 7 天
/// - `biweekly`：start 起每 14 天
///
/// [end] 是计划的**终止日期**（含当天；用户 2026-09-29「定投设置起始和终止日期」）：
/// 传了就取 `min(until, end)` 当上界，过期末不再生成。
///
/// **超过 [hardLimit] 期时返回最近的 [hardLimit] 期**（不是最早的那批）——
/// 日定投一天一期，计划建得早的话几千期都算得出来，取最近的对补记才有意义
/// （`pendingDcaDates` 会再按 `lastRunDate` 过滤）。
List<DateTime> dcaPeriods({
  required DateTime start,
  required DcaFrequency frequency,
  required int dayOfPeriod,
  required DateTime until,
  DateTime? end,
  int hardLimit = 600,
}) {
  var u = dayOnly(until);
  final e = end == null ? null : dayOnly(end);
  if (e != null && e.isBefore(u)) u = e;
  final s = dayOnly(start);
  if (u.isBefore(s)) return const [];

  final out = <DateTime>[];

  switch (frequency) {
    case DcaFrequency.daily:
      // 只要最近 hardLimit 天：从 start 一路数到 until 会在计划建得早时白算几千次
      final total = u.difference(s).inDays;
      var d = total > hardLimit - 1
          ? u.subtract(Duration(days: hardLimit - 1))
          : s;
      for (var i = 0; i < hardLimit && !d.isAfter(u); i++) {
        out.add(d);
        d = d.add(const Duration(days: 1));
      }
      break;

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

/// 从 `lastRunDate` 之后到 `today`（且不超过计划终止日期）的待补记日期。
///
/// 超过 [maxNew] 期时取**最早的** [maxNew] 期（不是最近的）——这样每期都会
/// 轮到：补完这 24 期后 `lastRunDate` 停在它们最后一期，剩下的下一轮继续补。
/// 以前取"最近 24 期"，日定投（一天一期）下中间那段会被永久跳过 ✗。
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
    // 终止日期之后不再补 —— 过了期末的计划不该继续生新期数
    end: plan.endDate,
  );
  final last = plan.lastRunDate;
  final pending =
      last == null ? all : all.where((d) => d.isAfter(dayOnly(last))).toList();
  if (pending.length <= maxNew) return pending;
  return pending.sublist(0, maxNew);
}

/// 手上这批「日期 → 价格」够不够算完 [due] 里的**每一期**？
///
/// 判定窗口与 [resolveDcaPrice] 的顺延规则一致：每一期都要能在
/// `[due, min(today, due + 12 天)]` 里找到价格（净值公布不会拖过 12 天）。
/// **不够就别省那次网络请求** —— 本地 nav_history 只覆盖在关注/持仓里的标的，
/// 定投计划指向别的基金时本地是空的。
bool coversAllDue(
  List<DateTime> due,
  Map<String, double> priceByDay,
  DateTime today,
) {
  if (priceByDay.isEmpty) return false;
  final t = dayOnly(today);
  for (final d in due) {
    final d0 = dayOnly(d);
    var found = false;
    for (var i = 0; i <= 12; i++) {
      final day = d0.add(Duration(days: i));
      if (day.isAfter(t)) break;
      final v = priceByDay[dayKey(day)];
      if (v != null && v > 0) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

/// 一期定投实际使用的成交日与价格
class DcaPriceRef {
  final DateTime date;
  final double price;
  const DcaPriceRef(this.date, this.price);
}

/// 给定应投日，从「日期 → 价格」表里定出实际成交日与价格。
///
/// 规则：**当天有价用当天；否则顺延到 `due` 之后、不超过 `today` 的第一个有价日**，
/// 但顺延**最多 [maxForwardDays] 天**（默认 15：够覆盖周末与最长约 9 天的长假）。
/// 找不到就返回 null —— 调用方应当**跳过该期且不越过断点**，下次再试。
/// 刻意不向前回退取价：那等于用定投日之前的净值成交，是错的。
///
/// ⚠️ 上限是 2026-09-30 补的：实测把一条"起始日在两年前"的计划补历史时，
/// 2024-10-01 那期被顺延到 **28 天后**（2024-10-29，基金成立首日、净值 1.0000）成交 ——
/// 那笔钱当时根本还没投进去，是"拿一个远在未来的价"冒充。超过 15 天只可能是
/// 休市/停牌/**基金还没成立**，都该如实跳过。
DcaPriceRef? resolveDcaPrice({
  required DateTime due,
  required DateTime today,
  required Map<String, double> priceByDay,
  int maxForwardDays = 15,
}) {
  final d0 = dayOnly(due);
  final t = dayOnly(today);

  final exact = priceByDay[dayKey(d0)];
  if (exact != null && exact > 0) return DcaPriceRef(d0, exact);

  var d = d0.add(const Duration(days: 1));
  final limit = d0.add(Duration(days: maxForwardDays));
  while (!d.isAfter(t) && !d.isAfter(limit)) {
    final p = priceByDay[dayKey(d)];
    if (p != null && p > 0) return DcaPriceRef(d, p);
    d = d.add(const Duration(days: 1));
  }
  return null;
}

/// 计划的下一次扣款日（用于 UI 展示）。已停止或已到期返回 null。
///
/// 「已到期」= 终止日期在今天之前（用户 2026-09-29 加的终止日期）。
DateTime? nextDcaDate(DcaPlan plan, DateTime today) {
  final t = dayOnly(today);
  if (plan.endedBy(t)) return null;
  // 从今天开始往后找第一个应投日（上界：一年后 或 终止日期，取先到的那个）
  final horizon = DateTime(t.year + 1, t.month, t.day);
  final future = dcaPeriods(
    start: t,
    frequency: plan.frequency,
    dayOfPeriod: plan.dayOfPeriod,
    until: horizon,
    end: plan.endDate,
    // 日定投只往后看几天就够（默认 600 期会白算一年）
    hardLimit: plan.frequency == DcaFrequency.daily ? 8 : 600,
  );
  if (future.isEmpty) return null;
  return future.first;
}

/// 该不该因为"持仓空了"把这个计划自动停用？
///
/// - **从来没交易过**这个标的（`everTraded == false`）→ 不停用：这正是
///   「搜一个没持有的标的、建计划开始投」的场景（用户 2026-09-29 加的搜索选目标），
///   第一笔买入会自己把持仓建起来；
/// - 有过交易、现在清仓了（`everTraded && positionEmpty`）→ 停用（老口径，
///   免得已清仓的标的继续被补记）。
bool shouldDisableForEmptyPosition({
  required bool everTraded,
  required bool positionEmpty,
}) =>
    everTraded && positionEmpty;

/// 一期定投的手续费（元）＝ 每期金额 × **每期申购费率（%）**，钱落到分。
///
/// 口径（用户 2026-09-25 拍板）：**每期金额是「买入金额」，手续费另外加** ——
/// 份额照旧按「金额 ÷ 净值」算，现金支出 = `金额 + 手续费`
/// （他的例子：买入 3000 元、费用 2.5 元 → 现金支出 3002.50 元）。
///
/// 费率为 0 或金额非法 → 0（不计手续费）。**刻意不去套账户里那个券商佣金率**：
/// 场外申购费（常见 0.1%）和券商佣金（他账户是万0.85）差十几倍，所以费率由
/// 每个计划自己填（见 `DcaPlan.feeRate`）。
double dcaFeeFor({required double amount, required double feeRatePct}) {
  if (amount <= 0 || feeRatePct <= 0) return 0;
  if (amount.isNaN ||
      amount.isInfinite ||
      feeRatePct.isNaN ||
      feeRatePct.isInfinite) {
    return 0;
  }
  return double.parse((amount * feeRatePct / 100).toStringAsFixed(2));
}

/// 该「账户 + 标的」在 [days] 里是否**已经有一笔定投记录** —— 补记时用来跳过。
///
/// 用户 2026-09-25 的口径：「**补记功能要检查补记当天是否有定投记录，有的话就应该不补**」。
/// 判定用备注里的「定投」：这是全 App 统一的定投标记（交易类型标签、现金流水的高亮、
/// 定投管理里的「已补记 N 笔」都认它），所以**你手动记的那笔定投也算数**。
/// [days] 传「应投日」与「实际成交日」两天，任一天命中就算记过 ——
/// 净值顺延时（比如应投日是周六、成交在周一）两者不是同一天。
///
/// ⚠️ 这是**账户+标的级**判定（不区分是哪条计划）。同一标的可以挂多条计划之后
/// （用户 2026-09-29），补记要用 [dcaPeriodRecorded] —— 否则 A 计划的期数会把
/// B 计划同一天的期数误判成"已记过"而漏补。
bool dcaRecordedOn({
  required Iterable<Txn> txns,
  required int accountId,
  required int assetId,
  required Iterable<DateTime> days,
}) {
  final keys = {for (final d in days) dayKey(d)};
  for (final t in txns) {
    if (t.accountId != accountId || t.assetId != assetId) continue;
    if (!t.note.contains('定投')) continue;
    if (keys.contains(dayKey(t.date))) return true;
  }
  return false;
}

/// 这一期是不是**这条计划**已经记过了（用户 2026-09-29：「补记功能只要期间没有」）
///
/// 判定顺序：
/// 1. **认计划标记**：`txn.dcaPlanId == plan.id` —— App 自动补记写的，最准；
/// 2. [legacyAssetWide] 为真时（这个「账户+标的」下**只有这一条计划**），再退回
///    老口径「同账户同标的同一天 + 备注含定投」：既认历史数据（没有 dcaPlanId），
///    也认**他手动记的那笔定投**（2026-09-25 定的口径）。
///    多计划共存时这条**必须关掉**，否则一条计划的记录会把另一条计划的同一天期数吞掉。
///
/// [days] 传「应投日」与「实际成交日」两天，任一天命中就算记过（净值顺延时不是同一天）。
bool dcaPeriodRecorded({
  required Iterable<Txn> txns,
  required DcaPlan plan,
  required Iterable<DateTime> days,
  required bool legacyAssetWide,
}) {
  final keys = {for (final d in days) dayKey(d)};
  for (final t in txns) {
    if (t.accountId != plan.accountId || t.assetId != plan.assetId) continue;
    if (!keys.contains(dayKey(t.date))) continue;
    if (plan.id != null && t.dcaPlanId == plan.id) return true;
    if (legacyAssetWide && t.note.contains('定投')) return true;
  }
  return false;
}
