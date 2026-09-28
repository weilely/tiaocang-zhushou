/// 场外基金**赎回费**：按持有天数的**档位表** ＋ **先进先出（FIFO）**分档
///
/// 用户 2026-09-28 发来参考图（中欧红利优享的「卖出费率分布」），要求：
/// ①持仓页能看「持有天数 × 区间份额 × 卖出费率」这张表；②卖出时**先进先出、按持仓天数估算费用**。
///
/// 口径（写在代码里，界面不另算）：
/// - **批次**：每笔**买入**（含定投、红利再投、期初持仓）的剩余份额；卖出按买入日期**先入先出**扣减。
///   0 份额的「成本调整」流水只动成本池，**不进批次**。
/// - **持有天数** = 批次买入日 → 卖出日（看分布时用今天）的**自然日**数。
/// - **档位区间左闭右开** `[minDays, maxDays)`，最后一档 `maxDays == null`（无上限）
///   —— 与图里的「0~7天 / 7~30天(不含)…」一致。
/// - **费用** = Σ（命中份额 × 当日净值 × 该档费率%），钱落到分。
/// - **只用来估算赎回费**：持仓与收益的成本口径仍是平均成本法（项目铁律：
///   收益口径不按类型分叉），FIFO 不参与成本计算。
/// - **T+1**：当天买入的那批**当天不能卖**（与 `sellableShares` 同一口径），
///   估算与分布都会把它排除。
library;

import '../data/fund_detail.dart';
import '../data/models.dart';

/// 赎回费率的一档
class RedeemTier {
  /// 含（天）
  final int minDays;

  /// 不含（天）；null = 无上限
  final int? maxDays;

  /// 费率（%）
  final double ratePct;

  const RedeemTier(this.minDays, this.maxDays, this.ratePct);

  /// 展示用文案，与参考图一致
  String get label => maxDays == null ? '≥$minDays 天' : '$minDays~$maxDays 天(不含)';

  bool contains(int days) {
    // 字段是 public，Dart 不做类型提升 → 先取到局部变量再判
    final max = maxDays;
    return days >= minDays && (max == null || days < max);
  }

  Map<String, Object?> toJson() =>
      {'min': minDays, 'max': maxDays, 'rate': ratePct};

  static RedeemTier? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final min = (raw['min'] as num?)?.toInt();
    final rate = (raw['rate'] as num?)?.toDouble();
    if (min == null || rate == null) return null;
    final max = (raw['max'] as num?)?.toInt();
    return RedeemTier(min, max, rate);
  }

  RedeemTier copyWith({double? ratePct}) =>
      RedeemTier(minDays, maxDays, ratePct ?? this.ratePct);
}

/// 内置默认档（**兜底用**：档案拿不到 / 没配 Key / 解析不出来时才用它）
///
/// 注意：**优先用基金档案里的赎回档位**（用户 2026-09-28：「得参考基金档案赎回费率」）——
/// 实测同一批基金档位数并不一样（004814 是 5 档、025497/021362/027858 只有 2 档），
/// 所以要靠 [parseRedeemTiers] 从档案解析，这套默认只是最后兜底。
const List<RedeemTier> kDefaultRedeemTiers = [
  RedeemTier(0, 7, 1.5),
  RedeemTier(7, 30, 0.75),
  RedeemTier(30, 365, 0.5),
  RedeemTier(365, 730, 0.25),
  RedeemTier(730, null, 0),
];

/// 把档案里的费率行解析成**赎回档位表**（按持有天数升序，认不出的跳过）
///
/// 真 Key 实测的文案形态（2026-09-28，`/api/fund/profile/detail` 的 `rate_info`）：
/// - `7天以下` 1.50% → `[0, 7)`
/// - `7天(包含)-30天` 0.75% → `[7, 30)`
/// - `30天(包含)-365天` 0.50% → `[30, 365)`
/// - `365天(包含)-730天` 0.25% → `[365, 730)`
/// - `730天以上(包含)` 0.00% → `[730, ∞)`
/// - `7天以上(包含)` 0.00% → `[7, ∞)`（两档型基金就是这一套）
///
/// 也容忍「小于/以内/不低于」这类写法；**不是百分比**的（如 `1000元/笔`）一律跳过。
/// 一条都解析不出来时返回空表 —— 调用方据此回落到默认档并**如实标注来源**。
List<RedeemTier> parseRedeemTiers(Iterable<FundRate> rates) {
  final out = <RedeemTier>[];
  for (final r in rates) {
    final t = tierFromRate(r);
    if (t != null) out.add(t);
  }
  out.sort((a, b) => a.minDays.compareTo(b.minDays));
  return out;
}

/// 单条费率行 → 一档（认不出返回 null）
RedeemTier? tierFromRate(FundRate r) {
  if (r.type != 'redemption') return null;
  final rate = pctOf(r.standardRate);
  if (rate == null) return null;
  final c = r.condition.trim();
  if (c.isEmpty) return null;

  // 「A天以下 / A天以内 / 小于A天」→ [0, A)
  if (_below.hasMatch(c)) {
    final m = _days.firstMatch(c);
    return m == null ? null : RedeemTier(0, int.parse(m.group(1)!), rate);
  }
  // 「A天以上(包含) / 不低于A天」→ [A, ∞)
  if (_above.hasMatch(c)) {
    final m = _days.firstMatch(c);
    return m == null ? null : RedeemTier(int.parse(m.group(1)!), null, rate);
  }
  // 「A天(包含)-B天」→ [A, B)
  final all = _days.allMatches(c).toList();
  if (all.length >= 2) {
    return RedeemTier(
      int.parse(all[0].group(1)!),
      int.parse(all[1].group(1)!),
      rate,
    );
  }
  return null;
}

final RegExp _days = RegExp(r'(\d+)\s*天');
final RegExp _below = RegExp(r'(以下|以内|小于|<|＜)');
final RegExp _above = RegExp(r'(以上|不低于|≥|>=)');

/// `"1.50%"` → `1.5`；不是百分比（`"1000元/笔"`、`""`）→ null
double? pctOf(String s) {
  final t = s.trim();
  if (!t.endsWith('%')) return null;
  return double.tryParse(t.substring(0, t.length - 1).trim());
}

/// 一个持仓批次
class RedeemLot {
  /// 买入日（只到天）
  final DateTime date;
  final double shares;

  const RedeemLot(this.date, this.shares);

  int daysAsOf(DateTime d) => _dayOnly(d).difference(date).inDays;

  RedeemLot copyWith({double? shares}) =>
      RedeemLot(date, shares ?? this.shares);
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 按 FIFO 把持仓拆成批次（升序，只留剩余份额 > 0 的）
///
/// [skipDay] 传 true（默认）时**剔除当天买入的批次** —— 那部分 T+1 当天不能卖，
/// 与 `sellableShares` 同一口径；看「卖出费率分布」时也用这个口径，
/// 免得把卖不掉的份额算进某一档。
List<RedeemLot> fifoLots(
  Iterable<Txn> txns, {
  required DateTime asOf,
  bool skipToday = true,
}) {
  final sorted = [...txns]..sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
    });
  final lots = <RedeemLot>[];
  for (final t in sorted) {
    // 成本调整只动成本池（0 份额），不进批次
    if (t.note == Txn.costAdjustNote) continue;
    if (t.type == TxnType.buy) {
      if (t.shares > 1e-9) lots.add(RedeemLot(_dayOnly(t.date), t.shares));
      continue;
    }
    if (t.type != TxnType.sell) continue;
    var left = t.shares;
    for (var i = 0; i < lots.length && left > 1e-9; i++) {
      final take = lots[i].shares < left ? lots[i].shares : left;
      left -= take;
      lots[i] = lots[i].copyWith(shares: lots[i].shares - take);
    }
  }
  final today = _dayOnly(asOf);
  return [
    for (final l in lots)
      if (l.shares > 1e-9 && !(skipToday && l.date == today)) l,
  ];
}

/// [days] 天落在哪一档
///
/// 先按区间精确命中；**档案解析出来的表可能有缺口**（比如只回了两档之外的写法），
/// 这时退到「minDays ≤ days 的最后一档」（也就是把它当成"从那天起就是这个费率"），
/// 免得缺口里的份额被当成 0 费率、把费用算少了。
RedeemTier? tierForDays(int days, List<RedeemTier> tiers) {
  if (tiers.isEmpty) return null;
  for (final t in tiers) {
    if (t.contains(days)) return t;
  }
  RedeemTier? prev;
  for (final t in tiers) {
    if (t.minDays <= days) {
      if (prev == null || t.minDays > prev.minDays) prev = t;
    }
  }
  return prev ?? tiers.first;
}

/// 「卖出费率分布」：每一档对应的**区间份额**（按 FIFO 之后的批次归属）
List<({RedeemTier tier, double shares})> tierBreakdown({
  required List<RedeemLot> lots,
  required DateTime asOf,
  required List<RedeemTier> tiers,
}) =>
    [
      for (final tier in tiers)
        (
          tier: tier,
          shares: lots
              .where((l) => tier.contains(l.daysAsOf(asOf)))
              .fold<double>(0, (a, l) => a + l.shares),
        ),
    ];

/// 卖出 [sellShares] 份时按 FIFO 估出来的赎回费（元）与逐批明细
///
/// 每批按**该批的持有天数**取档，`amount = 份额 × nav`，`fee = amount × 费率%`；
/// 全部相加后落到分。份额不够（sellShares 大于批次合计）时按实际能命中的部分算。
({double fee, List<({RedeemTier? tier, double shares, double amount, int days})> hits})
    estimateRedeemFee({
  required List<RedeemLot> lots,
  required double sellShares,
  required DateTime date,
  required double nav,
  required List<RedeemTier> tiers,
}) {
  var left = sellShares;
  var fee = 0.0;
  final hits = <({RedeemTier? tier, double shares, double amount, int days})>[];
  if (nav <= 0 || sellShares <= 0) {
    return (fee: 0, hits: hits);
  }
  for (final l in lots) {
    if (left <= 1e-9) break;
    final take = l.shares < left ? l.shares : left;
    if (take <= 1e-9) continue;
    final days = l.daysAsOf(date);
    final tier = tierForDays(days, tiers);
    final amount = take * nav;
    fee += amount * (tier?.ratePct ?? 0) / 100;
    hits.add((tier: tier, shares: take, amount: amount, days: days));
    left -= take;
  }
  return (fee: double.parse(fee.toStringAsFixed(2)), hits: hits);
}
