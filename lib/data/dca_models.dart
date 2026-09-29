import 'models.dart';

/// 定投频率
///
/// 「每日」是用户 2026-09-29 加的（原话：「定投周期增加日定投」）。
/// 注意它的 [DcaPlan.dayOfPeriod] **不参与**（每天都是期日）。
enum DcaFrequency { daily, weekly, biweekly, monthly }

extension DcaFrequencyX on DcaFrequency {
  String get label => switch (this) {
        DcaFrequency.daily => '每日',
        DcaFrequency.weekly => '每周',
        DcaFrequency.biweekly => '每两周',
        DcaFrequency.monthly => '每月',
      };

  /// 分段控件上的短标签（400dp + 字体 1.3 下四个段要挤得下）
  String get shortLabel => switch (this) {
        DcaFrequency.daily => '每日',
        DcaFrequency.weekly => '每周',
        DcaFrequency.biweekly => '两周',
        DcaFrequency.monthly => '每月',
      };

  String get key => name;
}

DcaFrequency dcaFrequencyFromName(String? s) => DcaFrequency.values
    .firstWhere((e) => e.name == s, orElse: () => DcaFrequency.monthly);

/// 一条定投计划
class DcaPlan {
  int? id;
  int accountId;
  int assetId;

  /// 每期金额
  double amount;
  DcaFrequency frequency;

  /// 每周：1=周一 … 7=周日；每月：1–28（避开月末）
  int dayOfPeriod;

  /// 首期日期
  DateTime startDate;

  /// **终止日期**（含当天；null = 不设终止、一直投下去）
  ///
  /// 用户 2026-09-29：「定投设置起始和终止日期」。到期末之后
  /// `pendingDcaDates` 不再生成新期数，`nextDcaDate` 返回 null（界面显示 `--`）。
  DateTime? endDate;

  /// 已补记到哪一期（null = 从未补记）
  DateTime? lastRunDate;

  bool enabled;
  String note;
  DateTime createdAt;

  /// **每期申购费率（%）** —— 定投也要算手续费（用户 2026-09-25 定的口径）
  ///
  /// 为什么不去套「记一笔」里那个账户佣金率：场外申购费（常见 0.1%）和券商佣金
  /// （他那账户是万0.85）根本不是一回事，量级差十几倍，所以**每个计划单独填**。
  /// 0 = 不计手续费。计算规则见 [dcaFeeFor]。
  double feeRate;

  DcaPlan({
    this.id,
    required this.accountId,
    required this.assetId,
    required this.amount,
    required this.frequency,
    required this.dayOfPeriod,
    required this.startDate,
    this.endDate,
    this.lastRunDate,
    this.enabled = true,
    this.note = '',
    this.feeRate = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 期日的展示文案
  String get dayLabel => switch (frequency) {
        DcaFrequency.daily => '每日',
        DcaFrequency.monthly => '每月 $dayOfPeriod 日',
        DcaFrequency.weekly => '每周${const ['', '一', '二', '三', '四', '五', '六', '日'][dayOfPeriod.clamp(1, 7)]}',
        DcaFrequency.biweekly => '每两周',
      };

  /// 起止区间（`2026-01-05 ~ 2026-12-31` / 无终止时只写起点）
  String get rangeLabel {
    final s = '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}'
        '-${startDate.day.toString().padLeft(2, '0')}';
    if (endDate == null) return '$s 起';
    final e = '${endDate!.year}-${endDate!.month.toString().padLeft(2, '0')}'
        '-${endDate!.day.toString().padLeft(2, '0')}';
    return '$s ~ $e';
  }

  /// 今天是否已过期（过了终止日期）
  bool endedBy(DateTime today) {
    final e = endDate;
    if (e == null) return false;
    final t = DateTime(today.year, today.month, today.day);
    final ee = DateTime(e.year, e.month, e.day);
    return t.isAfter(ee);
  }

  String get summary =>
      '$dayLabel · 每期 ${amount.toStringAsFixed(2)} 元 · $rangeLabel';

  Map<String, Object?> toMap() => {
        'id': id,
        'account_id': accountId,
        'asset_id': assetId,
        'amount': amount,
        'frequency': frequency.name,
        'day_of_period': dayOfPeriod,
        'start_date': startDate.millisecondsSinceEpoch,
        'end_date':
            endDate == null ? 0 : endDate!.millisecondsSinceEpoch,
        'last_run_date':
            lastRunDate == null ? 0 : lastRunDate!.millisecondsSinceEpoch,
        'enabled': enabled ? 1 : 0,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
        'fee_rate': feeRate,
      };

  factory DcaPlan.fromMap(Map<String, Object?> m) {
    final last = (m['last_run_date'] as num?)?.toInt() ?? 0;
    final end = (m['end_date'] as num?)?.toInt() ?? 0;
    return DcaPlan(
      id: m['id'] as int?,
      accountId: (m['account_id'] as num).toInt(),
      assetId: (m['asset_id'] as num).toInt(),
      amount: (m['amount'] as num?)?.toDouble() ?? 0,
      frequency: dcaFrequencyFromName(m['frequency'] as String?),
      dayOfPeriod: (m['day_of_period'] as num?)?.toInt() ?? 1,
      startDate:
          DateTime.fromMillisecondsSinceEpoch((m['start_date'] as num).toInt()),
      // 老库/老备份没有这一列 → 不设终止
      endDate: end <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(end),
      lastRunDate:
          last <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(last),
      enabled: ((m['enabled'] as num?)?.toInt() ?? 1) == 1,
      note: (m['note'] as String?) ?? '',
      // 老库/老备份没有这一列 → 0（不计手续费），不许报错
      feeRate: (m['fee_rate'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (m['created_at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch),
    );
  }

  DcaPlan copyWith({
    int? id,
    int? accountId,
    int? assetId,
    double? amount,
    DcaFrequency? frequency,
    int? dayOfPeriod,
    DateTime? startDate,
    DateTime? endDate,
    bool clearEndDate = false,
    DateTime? lastRunDate,
    bool? enabled,
    String? note,
    double? feeRate,
  }) =>
      DcaPlan(
        id: id ?? this.id,
        accountId: accountId ?? this.accountId,
        assetId: assetId ?? this.assetId,
        amount: amount ?? this.amount,
        frequency: frequency ?? this.frequency,
        dayOfPeriod: dayOfPeriod ?? this.dayOfPeriod,
        startDate: startDate ?? this.startDate,
        // `endDate: null` 与"不改"是同一种传参，所以要清空得显式说 clearEndDate
        endDate: clearEndDate ? null : (endDate ?? this.endDate),
        lastRunDate: lastRunDate ?? this.lastRunDate,
        enabled: enabled ?? this.enabled,
        note: note ?? this.note,
        feeRate: feeRate ?? this.feeRate,
        createdAt: createdAt,
      );
}

/// 一次自动补记的结果
class DcaRunReport {
  /// 生成了多少笔
  int created = 0;

  /// 因为取不到历史价格而跳过的期数
  int skippedNoPrice = 0;

  /// 因为**当天已经有定投记录**而跳过的期数
  ///
  /// 用户 2026-09-25：「补记功能要检查补记当天是否有定投记录，有的话就应该不补」。
  /// 手动记的那笔也算，所以这不是错，要如实报出来（免得他以为补记没生效）。
  int skippedRecorded = 0;

  /// 因为标的已清仓而停用的计划数
  int disabledPlans = 0;

  /// 这些补记期一共算出来的手续费（元）—— 现金支出里已经含它
  double feeTotal = 0;

  final List<String> messages = [];

  bool get hasAnything =>
      created > 0 ||
      skippedNoPrice > 0 ||
      skippedRecorded > 0 ||
      disabledPlans > 0;

  String get summary {
    final parts = <String>[];
    if (created > 0) {
      final fee = feeTotal > 0 ? '（含手续费 ¥${feeTotal.toStringAsFixed(2)}）' : '';
      parts.add('已按定投计划补记 $created 笔$fee');
    }
    if (skippedRecorded > 0) {
      parts.add('$skippedRecorded 期当天已记过定投，未重复补');
    }
    if (skippedNoPrice > 0) parts.add('$skippedNoPrice 期因取不到历史价格未补记');
    if (disabledPlans > 0) parts.add('$disabledPlans 个计划因标的已清仓而暂停');
    return parts.isEmpty ? '没有需要补记的定投' : parts.join('；');
  }
}

/// 份额取整：场外基金保留 2 位小数，股票/ETF 向下取整
double roundDcaShares(double shares, AssetKind kind) {
  if (shares <= 0 || shares.isNaN || shares.isInfinite) return 0;
  if (kind == AssetKind.fund) {
    return (shares * 100).floorToDouble() / 100;
  }
  return shares.floorToDouble();
}
