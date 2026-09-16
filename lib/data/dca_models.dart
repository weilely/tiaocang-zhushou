import 'models.dart';

/// 定投频率
enum DcaFrequency { weekly, biweekly, monthly }

extension DcaFrequencyX on DcaFrequency {
  String get label => switch (this) {
        DcaFrequency.weekly => '每周',
        DcaFrequency.biweekly => '每两周',
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

  /// 已补记到哪一期（null = 从未补记）
  DateTime? lastRunDate;

  bool enabled;
  String note;
  DateTime createdAt;

  DcaPlan({
    this.id,
    required this.accountId,
    required this.assetId,
    required this.amount,
    required this.frequency,
    required this.dayOfPeriod,
    required this.startDate,
    this.lastRunDate,
    this.enabled = true,
    this.note = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 期日的展示文案
  String get dayLabel => switch (frequency) {
        DcaFrequency.monthly => '每月 $dayOfPeriod 日',
        DcaFrequency.weekly => '每周${const ['', '一', '二', '三', '四', '五', '六', '日'][dayOfPeriod.clamp(1, 7)]}',
        DcaFrequency.biweekly => '自首期起每 14 天',
      };

  String get summary => '$dayLabel · 每期 ${amount.toStringAsFixed(2)} 元';

  Map<String, Object?> toMap() => {
        'id': id,
        'account_id': accountId,
        'asset_id': assetId,
        'amount': amount,
        'frequency': frequency.name,
        'day_of_period': dayOfPeriod,
        'start_date': startDate.millisecondsSinceEpoch,
        'last_run_date':
            lastRunDate == null ? 0 : lastRunDate!.millisecondsSinceEpoch,
        'enabled': enabled ? 1 : 0,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory DcaPlan.fromMap(Map<String, Object?> m) {
    final last = (m['last_run_date'] as num?)?.toInt() ?? 0;
    return DcaPlan(
      id: m['id'] as int?,
      accountId: (m['account_id'] as num).toInt(),
      assetId: (m['asset_id'] as num).toInt(),
      amount: (m['amount'] as num?)?.toDouble() ?? 0,
      frequency: dcaFrequencyFromName(m['frequency'] as String?),
      dayOfPeriod: (m['day_of_period'] as num?)?.toInt() ?? 1,
      startDate:
          DateTime.fromMillisecondsSinceEpoch((m['start_date'] as num).toInt()),
      lastRunDate:
          last <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(last),
      enabled: ((m['enabled'] as num?)?.toInt() ?? 1) == 1,
      note: (m['note'] as String?) ?? '',
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
    DateTime? lastRunDate,
    bool? enabled,
    String? note,
  }) =>
      DcaPlan(
        id: id ?? this.id,
        accountId: accountId ?? this.accountId,
        assetId: assetId ?? this.assetId,
        amount: amount ?? this.amount,
        frequency: frequency ?? this.frequency,
        dayOfPeriod: dayOfPeriod ?? this.dayOfPeriod,
        startDate: startDate ?? this.startDate,
        lastRunDate: lastRunDate ?? this.lastRunDate,
        enabled: enabled ?? this.enabled,
        note: note ?? this.note,
        createdAt: createdAt,
      );
}

/// 一次自动补记的结果
class DcaRunReport {
  /// 生成了多少笔
  int created = 0;

  /// 因为取不到历史价格而跳过的期数
  int skippedNoPrice = 0;

  /// 因为标的已清仓而停用的计划数
  int disabledPlans = 0;

  final List<String> messages = [];

  bool get hasAnything =>
      created > 0 || skippedNoPrice > 0 || disabledPlans > 0;

  String get summary {
    final parts = <String>[];
    if (created > 0) parts.add('已按定投计划补记 $created 笔');
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
