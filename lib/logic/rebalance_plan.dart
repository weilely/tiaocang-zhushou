/// 调仓方案的计算口径
///
/// 与设计稿 `pic/111.jpg` 上的数字一一对应（用设计稿的样例可以逐条验算）：
///
/// ```text
/// 调仓总金额 = Σ预估 + 追加调仓金额          329231.57 = 319231.57 + 10000
/// 预估       = 份额 × 预估净值                31043.31 = 17601.9 × 1.7637
/// 目标       = 目标占比 × 调仓总金额          32923.16 = 10% × 329231.57
/// 差额       = 目标 − 预估                    1879.85
/// 调仓份额   = 差额 ÷ 预估净值                1065.86 = 1879.85 ÷ 1.7637
/// 偏离       = 差额 ÷ 预估                    6.06%   = 1879.85 ÷ 31043.31
/// ```
///
/// 「偏离」按**相对量**算（差额 ÷ 预估），不是占比的百分点之差 —— 5% 的阈值配的
/// 就是它：设计稿里的卡片偏离 6.06% > 5%，所以顶上那条「有基金偏离目标比例超过
/// 5%，建议调仓」才会出现。
///
/// 预估净值：场内标的（ETF / 股票）就是**实时价**；场外基金没有实时行情，
/// 用「最新已公布净值 × (1 + 当日预估涨幅)」，而当日预估涨幅是
/// **关联 ETF 实时涨幅 × 95%**（见 `logic/link_etf.dart`）。今天的净值已经公布时
/// 涨幅记 0 —— 当天已经结束，再估就把涨幅算两遍了。
library;

import '../data/models.dart';

/// 场外基金用关联 ETF 涨幅折算的比例
///
/// 一开始按「联接基金约 95% 仓位」取 0.95，现在按需求改成**直接取 ETF 的涨幅**：
/// 卡片上「当日预估涨幅」里写的就是「关联ETF」那一行的数，一眼能对上。
/// 想恢复折算把这个常量改回 0.95 即可（单测里有对应的断言）。
const double kFundEstimateFactor = 1.0;

/// 一只标的进方案前需要的东西（由 AppState 从行情、历史净值、目标里拼出来）
class PlanTarget {
  final int? assetId;
  final String code;
  final String name;
  final AssetKind kind;

  /// 持有份额（同标的多账户已合并）
  final double shares;

  /// 预估净值：场内 = 实时价，场外 = 最新净值 ×(1+涨幅)
  final double? nav;

  /// 场外基金的基准（最新已公布净值）
  final double? baseNav;

  /// 基准净值的日期
  final String? navDate;

  /// 当日涨幅（%）：今天的净值已公布时是**真实涨幅**，否则是估算值
  final double pct;

  /// 今天的净值是否已公布（true → 卡片不写"预估"，涨幅也不可手改）
  final bool navIsActual;

  /// 涨幅是不是实时行情（场内有行情 / 场外关联 ETF 有行情）
  final bool realtimePct;

  /// 关联 ETF（仅场外基金）
  final String linkCode;
  final String linkName;

  /// 关联 ETF 的实时涨幅（%），没取到为 null
  final double? linkPct;

  /// 目标占比（0..1）
  final double targetRatio;
  final bool hasTarget;

  const PlanTarget({
    this.assetId,
    required this.code,
    required this.name,
    required this.kind,
    required this.shares,
    required this.nav,
    this.baseNav,
    this.navDate,
    this.pct = 0,
    this.navIsActual = false,
    this.realtimePct = false,
    this.linkCode = '',
    this.linkName = '',
    this.linkPct,
    this.targetRatio = 0,
    this.hasTarget = false,
  });

  bool get hasNav => nav != null && nav! > 0;
}

/// 方案里的一行
class PlanLine {
  final PlanTarget target;

  /// 预估市值
  final double est;

  /// 目标市值
  final double targetValue;

  /// 目标 − 预估（正=需买入）
  final double diff;

  /// 调仓份额（份额取整口径与记一笔一致）
  final double planShares;

  /// 偏离（%）= 差额 ÷ 预估
  final double devPct;

  /// 占全部预估市值的比（进度条就是它）
  final double weight;

  /// 是否超过阈值
  final bool exceeded;

  const PlanLine({
    required this.target,
    required this.est,
    required this.targetValue,
    required this.diff,
    required this.planShares,
    required this.devPct,
    required this.weight,
    required this.exceeded,
  });

  bool get isBuy => diff > 0;

  /// 有明确动作（未设目标的标的只显示现状）
  bool get hasAction => target.hasTarget && diff.abs() > 0.005;
}

/// 整个方案
class RebalancePlan {
  final List<PlanLine> lines;

  /// 追加调仓金额
  final double extraAmount;

  /// 调仓基金市值 = Σ预估
  final double estTotal;

  /// 调仓总金额 = 调仓基金市值 + 追加调仓金额
  final double total;

  final double threshold;

  /// Σ目标占比（未设目标的不计）
  final double targetSum;

  const RebalancePlan({
    required this.lines,
    required this.extraAmount,
    required this.estTotal,
    required this.total,
    required this.threshold,
    required this.targetSum,
  });

  int get buyCount => lines.where((l) => l.hasAction && l.isBuy).length;
  int get sellCount => lines.where((l) => l.hasAction && !l.isBuy).length;
  int get unsetCount => lines.where((l) => !l.target.hasTarget).length;
  bool get anyExceeded => lines.any((l) => l.exceeded);
  bool get isEmpty => lines.isEmpty;
}

/// 调仓份额取整：场外基金 2 位小数，股票/ETF 取整
///
/// 与定投 / 记一笔的 `roundDcaShares` 不同：那里是**向下取整**（钱是固定的，
/// 不能多买），这里只是给方案一个好看又好下单的数，按设计稿取最近值。
/// 卖出方向（负份额）按绝对值取整后保留符号。
double roundPlanShares(double shares, AssetKind kind) {
  if (shares.isNaN || shares.isInfinite) return 0;
  final v = shares.abs();
  if (v <= 0) return 0;
  final r = kind == AssetKind.fund
      ? (v * 100).roundToDouble() / 100
      : v.roundToDouble();
  return shares < 0 ? -r : r;
}

/// 场外基金当日预估涨幅
///
/// - 今日净值已公布 → 0（当天结束，不能再叠一层估计）
/// - 有 [linkChangePct]（关联 ETF 的涨幅）→ **直接用它**（默认 ×1.0）
/// - 否则为 0
double fundEstimatePct({
  required bool navPublishedToday,
  double? linkChangePct,
  double factor = kFundEstimateFactor,
}) {
  if (navPublishedToday) return 0;
  if (linkChangePct == null || linkChangePct.isNaN) return 0;
  return linkChangePct * factor;
}

/// 预估净值
double? planNavFor({
  required AssetKind kind,
  required double? baseNav,
  required double pct,
  double? realtimePrice,
}) {
  if (kind == AssetKind.fund) {
    if (baseNav == null || baseNav <= 0) return null;
    return baseNav * (1 + pct / 100);
  }
  if (realtimePrice != null && realtimePrice > 0) return realtimePrice;
  return (baseNav != null && baseNav > 0) ? baseNav : null;
}

/// 场外标的当天的取价口径
///
/// - **今天的净值已公布** → 直接用当日净值与**真实当日涨幅**，界面不该再写"预估"
/// - 没公布 → 用关联 ETF 的实时涨幅（或基金自己的盘中估值）估一个，标签写"预估"
class FundQuote {
  /// 用来算市值的净值（actual 时就是当日净值）
  final double? nav;

  /// 当日涨幅（%）：actual 时是库里那条净值自己的涨幅
  final double pct;

  /// 今天的净值是否已公布
  final bool actual;

  const FundQuote({required this.nav, required this.pct, required this.actual});
}

/// 按上面的口径算场外基金当天的净值与涨幅
FundQuote resolveFundQuote({
  required double? baseNav,
  required double baseChangePct,
  required bool navPublishedToday,
  double? linkChangePct,
  double? ownEstPct,
  double? overridePct,
}) {
  if (navPublishedToday) {
    // 当天已经结束：净值、涨幅都用真实的，手改也没意义（界面不再给输入框）
    return FundQuote(nav: baseNav, pct: baseChangePct, actual: true);
  }
  final auto = linkChangePct != null
      ? fundEstimatePct(navPublishedToday: false, linkChangePct: linkChangePct)
      : (ownEstPct ?? 0);
  final pct = overridePct ?? auto;
  return FundQuote(
    nav: planNavFor(kind: AssetKind.fund, baseNav: baseNav, pct: pct),
    pct: pct,
    actual: false,
  );
}

/// 拼方案
RebalancePlan buildRebalancePlan({
  required List<PlanTarget> targets,
  required double extraAmount,
  double threshold = 0.05,
}) {
  final extra = extraAmount.isFinite && extraAmount > 0 ? extraAmount : 0.0;

  // 先算每只的预估市值，才知道调仓总金额
  final ests = <double>[
    for (final t in targets) t.hasNav ? t.shares * t.nav! : 0,
  ];
  final estTotal = ests.fold<double>(0, (a, b) => a + b);
  final total = estTotal + extra;

  final lines = <PlanLine>[];
  for (var i = 0; i < targets.length; i++) {
    final t = targets[i];
    final est = ests[i];
    // 未设目标 = 保持现状，不给买卖建议
    final targetValue = t.hasTarget ? t.targetRatio * total : est;
    final diff = t.hasTarget ? targetValue - est : 0.0;
    final nav = t.nav;
    final shares = (nav != null && nav > 0 && diff != 0)
        ? roundPlanShares(diff / nav, t.kind)
        : 0.0;
    final devPct = (est > 0) ? diff / est * 100 : 0.0;
    lines.add(PlanLine(
      target: t,
      est: est,
      targetValue: targetValue,
      diff: diff,
      planShares: shares,
      devPct: devPct,
      weight: estTotal > 0 ? est / estTotal : 0,
      exceeded: t.hasTarget && devPct.abs() > threshold * 100,
    ));
  }

  lines.sort((a, b) => b.est.compareTo(a.est));

  return RebalancePlan(
    lines: lines,
    extraAmount: extra,
    estTotal: estTotal,
    total: total,
    threshold: threshold,
    targetSum: targets
        .where((t) => t.hasTarget)
        .fold<double>(0, (a, t) => a + t.targetRatio),
  );
}
