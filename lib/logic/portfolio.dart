import 'dart:math' as math;

import '../data/models.dart';

/// 一笔现金流（XIRR 用）：负数为投入资金，正数为收回资金
class CashFlow {
  final DateTime date;
  final double amount;
  const CashFlow(this.date, this.amount);
}

/// 年化内部收益率（XIRR，按 365 天计息）。
/// 无解（例如全为同向现金流）时返回 [double.nan]。
double xirr(List<CashFlow> flows) {
  final valid = flows.where((f) => f.amount != 0).toList();
  if (valid.length < 2) return double.nan;

  final hasPos = valid.any((f) => f.amount > 0);
  final hasNeg = valid.any((f) => f.amount < 0);
  if (!hasPos || !hasNeg) return double.nan;

  final t0 = valid
      .map((f) => f.date)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  double npv(double r) {
    var sum = 0.0;
    for (final f in valid) {
      final years = f.date.difference(t0).inMinutes / (365.0 * 24 * 60);
      sum += f.amount / math.pow(1 + r, years);
    }
    return sum;
  }

  // 先用二分法在一个宽阔区间内定位符号变化
  var lo = -0.9999;
  var hi = 1.0;
  var fLo = npv(lo);
  var fHi = npv(hi);

  var guard = 0;
  while (fLo * fHi > 0 && guard < 60) {
    hi = hi * 2 + 1;
    fHi = npv(hi);
    guard++;
  }
  if (fLo * fHi > 0) return double.nan;

  for (var i = 0; i < 300; i++) {
    final mid = (lo + hi) / 2;
    final fMid = npv(mid);
    if (fMid.abs() < 1e-10 || (hi - lo).abs() < 1e-12) return mid;
    if (fLo * fMid <= 0) {
      hi = mid;
      fHi = fMid;
    } else {
      lo = mid;
      fLo = fMid;
    }
  }
  return (lo + hi) / 2;
}

/// 一个「账户 + 标的」的持仓（由交易流水推导）
class Position {
  final int accountId;
  final Asset asset;

  /// 当前持有份额
  final double shares;

  /// 当前持仓的总成本（含买入手续费，已按卖出份额扣减）
  final double cost;

  /// 已实现收益（卖出价差 + 分红）
  final double realized;

  /// 累计投入现金（买入金额 + 手续费）
  final double invested;

  /// 累计收回现金（卖出净额 + 分红）
  final double returned;

  final Quote? quote;
  final List<Txn> txns;
  final DateTime asOf;

  Position({
    required this.accountId,
    required this.asset,
    required this.shares,
    required this.cost,
    required this.realized,
    required this.invested,
    required this.returned,
    required this.quote,
    required this.txns,
    DateTime? asOf,
  }) : asOf = asOf ?? DateTime.now();

  bool get isEmpty => shares <= 1e-9;

  double get price => quote?.price ?? 0;

  bool get hasQuote => quote != null && quote!.price > 0;

  double get marketValue => shares * price;

  double get avgCost => shares > 1e-9 ? cost / shares : 0;

  /// 浮动盈亏
  double get floating => hasQuote ? marketValue - cost : 0;

  /// 浮动盈亏率（相对持仓成本）。取不到行情时为 null——不要把「无数据」当成 0%。
  ///
  /// 平均成本法下它恒等于 `现价 / 成本单价 − 1`，因此**部分卖出后保持不变**。
  double? get floatingPctOrNull =>
      hasQuote && cost.abs() > 1e-9 ? floating / cost * 100 : null;

  /// 浮动盈亏率；无行情时返回 0（仅用于内部归一化，UI 请用 [floatingPctOrNull]）
  double get floatingPct => floatingPctOrNull ?? 0;

  /// 持仓收益（浮动盈亏）：平均成本口径，卖出后不变
  double get holdingPnl => floating;
  double get holdingPct => floatingPct;

  /// 累计收益：建仓以来买卖产生的**全部**收益 = 持仓收益 + 已实现收益
  double get cumulativePnl => hasQuote ? floating + realized : realized;

  /// 累计收益率（相对累计投入本金）
  double get cumulativePct => invested.abs() > 1e-9 ? cumulativePnl / invested * 100 : 0;

  // 旧命名兼容
  double get totalPnl => cumulativePnl;
  double get totalPct => cumulativePct;

  /// 当日收益：最近一个交易日的涨跌带来的盈亏。
  ///
  /// 当天没有行情时（周末 / 节假日 / 尚未开盘），它反映的是**上一个交易日**的收益，
  /// 标签统一叫「当日收益」（见 [dayPnlLabel]），不按日期改名。
  double get dayPnl {
    final q = quote;
    if (q == null || shares <= 1e-9) return 0;
    var prev = q.prevClose;
    if (prev <= 0 && q.changePct.abs() < 100) {
      final denom = 1 + q.changePct / 100;
      if (denom.abs() > 1e-9) prev = q.price / denom;
    }
    if (prev <= 0) return 0;
    return (q.price - prev) * shares;
  }

  /// 当日收益对应的交易日
  DateTime? get dayPnlDay => quote?.tradeDay;

  /// 行情是否就是今天的
  bool get isDayPnlToday => quote?.isTradeDayToday() ?? false;

  /// 标签**固定**为「当日收益」
  ///
  /// 以前行情就是今天时叫「今日收益」、否则叫「前日收益 09-11」，同一块界面
  /// 在不同日子换字，看着像两套口径。现在统一成「当日收益」：
  /// 数值口径不变（仍取最近一个交易日的涨跌），要看是哪一天就看总览的
  /// 「市值更新日期」。
  String get dayPnlLabel => '当日收益';

  /// 与 [dayPnlLabel] 相同，保留这个名字只为少改调用点
  String get dayPnlLabelWithDate => dayPnlLabel;

  /// 当日收益率（相对前一交易日市值）
  double get dayPnlPct {
    final base = marketValue - dayPnl;
    return base.abs() > 1e-9 ? dayPnl / base * 100 : 0;
  }

  /// 净投入 = 投入 - 已收回
  double get netInvested => invested - returned;

  /// 该持仓的现金流序列（含当前市值作为期末流入）
  List<CashFlow> get flows {
    final list = <CashFlow>[];
    for (final t in txns) {
      list.add(CashFlow(t.date, t.netCash));
    }
    if (hasQuote && shares > 1e-9) {
      list.add(CashFlow(asOf, marketValue));
    }
    return list;
  }

  /// 年化收益率（%），无法计算返回 NaN
  double get xirrPct {
    final r = xirr(flows);
    return r.isNaN ? double.nan : r * 100;
  }
}

/// 由交易流水推导持仓列表
///
/// 成本核算采用「移动加权平均成本法」，与主流券商/基金平台口径一致。
List<Position> buildPositions({
  required List<Txn> txns,
  required Map<int, Asset> assets,
  required Map<String, Quote> quotes,
  DateTime? asOf,
}) {
  final grouped = <String, List<Txn>>{};
  for (final t in txns) {
    grouped.putIfAbsent('${t.accountId}#${t.assetId}', () => <Txn>[]).add(t);
  }

  final result = <Position>[];
  for (final entry in grouped.entries) {
    final list = List<Txn>.from(entry.value)
      ..sort((a, b) => a.date.compareTo(b.date));
    final asset = assets[list.first.assetId];
    if (asset == null) continue;

    var shares = 0.0;
    var cost = 0.0;
    var realized = 0.0;
    var invested = 0.0;
    var returned = 0.0;

    for (final t in list) {
      switch (t.type) {
        case TxnType.buy:
          invested += t.amount + t.fee;
          shares += t.shares;
          cost += t.amount + t.fee;
          break;
        case TxnType.sell:
          final avg = shares > 1e-9 ? cost / shares : 0.0;
          // 超卖（录入份额大于持仓）时按实际可卖份额折算，
          // 否则现金回收记全额、成本只扣一部分，两个口径会打架
          final sold = math.min(t.shares, shares);
          final ratio = t.shares > 1e-9 ? sold / t.shares : 0.0;
          final proceeds = (t.amount - t.fee) * ratio;
          realized += proceeds - avg * sold;
          cost -= avg * sold;
          shares -= sold;
          returned += proceeds;
          break;
        case TxnType.dividend:
          realized += t.amount;
          returned += t.amount;
          break;
      }
    }

    // 数学上成本恒 >= 0，出现负值只可能是浮点误差（用绝对阈值在大额成本下会漏）
    if (cost < 0 || cost.abs() < 1e-9) cost = 0;
    if (shares.abs() < 1e-9) {
      shares = 0;
      cost = 0;
    }

    result.add(Position(
      accountId: list.first.accountId,
      asset: asset,
      shares: shares,
      cost: cost,
      realized: realized,
      invested: invested,
      returned: returned,
      quote: quotes[asset.code],
      txns: list,
      asOf: asOf,
    ));
  }

  result.sort((a, b) => b.marketValue.compareTo(a.marketValue));
  return result;
}

/// 组合汇总
class PortfolioSummary {
  final double marketValue;
  final double cost;
  final double floating;
  final double realized;
  final double invested;
  final double returned;
  /// 当日收益（口径见 [dayPnlLabel]）
  final double dayPnl;

  /// 当日收益对应的交易日（yyyy-MM-dd）；未知为 null
  final String? dayPnlDate;

  /// 当日收益是否就是今天的
  final bool isDayPnlToday;

  final double floatingPct;
  final double totalPct;
  final double xirrPct;
  final int holdingCount;

  const PortfolioSummary({
    required this.marketValue,
    required this.cost,
    required this.floating,
    required this.realized,
    required this.invested,
    required this.returned,
    required this.dayPnl,
    required this.dayPnlDate,
    required this.isDayPnlToday,
    required this.floatingPct,
    required this.totalPct,
    required this.xirrPct,
    required this.holdingCount,
  });

  double get totalPnl => floating + realized;

  double get netInvested => invested - returned;

  /// 持仓收益（浮动盈亏）：平均成本口径，卖出后不变
  double get holdingPnl => floating;
  double get holdingPct => floatingPct;

  /// 累计收益：建仓以来买卖产生的全部收益 = 持仓收益 + 已实现收益
  double get cumulativePnl => floating + realized;
  double get cumulativePct => totalPct;

  /// 标签**固定**为「当日收益」（口径见 [Position.dayPnlLabel]）
  String get dayPnlLabel => '当日收益';

  /// 与 [dayPnlLabel] 相同，保留这个名字只为少改调用点
  String get dayPnlLabelWithDate => dayPnlLabel;

  /// 当日收益率（相对前一交易日市值）
  double get dayPnlPct {
    final base = marketValue - dayPnl;
    return base.abs() > 1e-9 ? dayPnl / base * 100 : 0;
  }

  static const empty = PortfolioSummary(
    marketValue: 0,
    cost: 0,
    floating: 0,
    realized: 0,
    invested: 0,
    returned: 0,
    dayPnl: 0,
    dayPnlDate: null,
    isDayPnlToday: false,
    floatingPct: 0,
    totalPct: 0,
    xirrPct: double.nan,
    holdingCount: 0,
  );
}

PortfolioSummary summarize(List<Position> positions) {
  if (positions.isEmpty) return PortfolioSummary.empty;

  var mv = 0.0, cost = 0.0, realized = 0.0, invested = 0.0, returned = 0.0, day = 0.0;
  var count = 0;
  DateTime? dayDate;
  final flows = <CashFlow>[];

  for (final p in positions) {
    if (!p.isEmpty) {
      mv += p.marketValue;
      cost += p.cost;
      day += p.dayPnl;
      // 取最新一个交易日，作为整体「当日收益」的日期
      final d = p.dayPnlDay;
      if (d != null && (dayDate == null || d.isAfter(dayDate))) dayDate = d;
      count++;
      flows.addAll(p.flows);
    }
    realized += p.realized;
    invested += p.invested;
    returned += p.returned;
  }

  final floating = mv - cost;
  final r = xirr(flows);

  final dd = dayDate;
  final now = DateTime.now();
  final isToday = dd != null &&
      dd.year == now.year &&
      dd.month == now.month &&
      dd.day == now.day;

  return PortfolioSummary(
    marketValue: mv,
    cost: cost,
    floating: floating,
    realized: realized,
    invested: invested,
    returned: returned,
    dayPnl: day,
    dayPnlDate: dd == null
        ? null
        : '${dd.year.toString().padLeft(4, '0')}-'
            '${dd.month.toString().padLeft(2, '0')}-'
            '${dd.day.toString().padLeft(2, '0')}',
    isDayPnlToday: isToday,
    floatingPct: cost.abs() > 1e-9 ? floating / cost * 100 : 0,
    totalPct: invested.abs() > 1e-9 ? (floating + realized) / invested * 100 : 0,
    xirrPct: r.isNaN ? double.nan : r * 100,
    holdingCount: count,
  );
}

/// 占比切片
class AllocationSlice {
  final String key;
  final String label;
  final double value;
  final double ratio;
  final int count;

  const AllocationSlice({
    required this.key,
    required this.label,
    required this.value,
    required this.ratio,
    this.count = 0,
  });
}

List<AllocationSlice> _toSlices(Map<String, double> values, Map<String, String> labels) {
  final total = values.values.fold<double>(0, (a, b) => a + b);
  final list = values.entries
      .where((e) => e.value.abs() > 1e-6)
      .map((e) => AllocationSlice(
            key: e.key,
            label: labels[e.key] ?? e.key,
            value: e.value,
            ratio: total.abs() > 1e-9 ? e.value / total : 0,
          ))
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return list;
}

/// 按标的类型统计占比
List<AllocationSlice> allocationByKind(List<Position> positions) {
  final values = <String, double>{};
  final labels = <String, String>{};
  for (final p in positions) {
    if (p.isEmpty) continue;
    final k = TargetAlloc.kindKey(p.asset.kind);
    values[k] = (values[k] ?? 0) + p.marketValue;
    labels[k] = p.asset.kind.label;
  }
  return _toSlices(values, labels);
}

/// 按账户统计占比
List<AllocationSlice> allocationByAccount(
    List<Position> positions, Map<int, Account> accounts) {
  final values = <String, double>{};
  final labels = <String, String>{};
  for (final p in positions) {
    if (p.isEmpty) continue;
    final k = 'acct:${p.accountId}';
    values[k] = (values[k] ?? 0) + p.marketValue;
    labels[k] = accounts[p.accountId]?.name ?? '未知账户';
  }
  return _toSlices(values, labels);
}

/// 按占比**升序**重排（首页持仓分布用）
///
/// 圆环图与图例的颜色都是按下标取的，所以两边必须用**同一份顺序** ——
/// 只把图例排序会让颜色和图例对不上。
List<AllocationSlice> sortSlicesAscending(List<AllocationSlice> slices) =>
    List<AllocationSlice>.of(slices)
      ..sort((a, b) => a.value.compareTo(b.value));

/// 按单个标的统计占比
List<AllocationSlice> allocationByAsset(List<Position> positions) {
  final values = <String, double>{};
  final labels = <String, String>{};
  for (final p in positions) {
    if (p.isEmpty) continue;
    final k = TargetAlloc.assetKey(p.asset.code);
    values[k] = (values[k] ?? 0) + p.marketValue;
    labels[k] = p.asset.displayName;
  }
  return _toSlices(values, labels);
}

/// 按用户自定义分类统计占比（再平衡依据）
List<AllocationSlice> allocationByCategory(List<Position> positions) {
  final values = <String, double>{};
  final labels = <String, String>{};
  for (final p in positions) {
    if (p.isEmpty) continue;
    final name = p.asset.effectiveCategory;
    final k = TargetAlloc.categoryKey(name);
    values[k] = (values[k] ?? 0) + p.marketValue;
    labels[k] = name;
  }
  return _toSlices(values, labels);
}

/// 当前实际存在的分类名
Set<String> categoryNamesInUse(List<Position> positions) => positions
    .where((p) => !p.isEmpty)
    .map((p) => p.asset.effectiveCategory)
    .toSet();

/// 再平衡建议项
class RebalanceItem {
  final String key;
  final String label;
  final double targetRatio;
  final double actualRatio;
  final double value;
  final double threshold;

  const RebalanceItem({
    required this.key,
    required this.label,
    required this.targetRatio,
    required this.actualRatio,
    required this.value,
    required this.threshold,
  });

  /// 偏离度（实际 - 目标）
  double get diffRatio => actualRatio - targetRatio;

  bool get needsRebalance => diffRatio.abs() > threshold;

  /// 偏离方向描述
  String get direction => diffRatio > 0 ? '超配' : '低配';

  /// 达成目标所需调整的金额（正=需买入，负=需卖出）
  double suggestAmount(double totalValue) => targetRatio * totalValue - value;
}

/// 计算再平衡情况
List<RebalanceItem> computeRebalance({
  required List<AllocationSlice> actual,
  required List<TargetAlloc> targets,
  required double totalValue,
  double threshold = 0.05,
}) {
  final map = {for (final s in actual) s.key: s};
  final items = <RebalanceItem>[];

  for (final t in targets) {
    if (t.ratio <= 0) continue;
    final slice = map[t.key];
    items.add(RebalanceItem(
      key: t.key,
      label: t.label.isNotEmpty ? t.label : (slice?.label ?? t.key),
      targetRatio: t.ratio,
      actualRatio: slice?.ratio ?? 0,
      value: slice?.value ?? 0,
      threshold: threshold,
    ));
  }

  items.sort((a, b) => b.diffRatio.abs().compareTo(a.diffRatio.abs()));
  return items;
}
