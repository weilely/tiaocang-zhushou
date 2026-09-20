/// 逐日组合序列引擎：日历图、趋势图、资金流三处共用。
///
/// 全部为纯函数，不依赖 Flutter 与数据库，便于单测。
///
/// ## 口径
///
/// 与 `Portfolio.buildPositions` 的「移动加权平均成本法」严格对齐，包含**超卖折算**
/// （卖出的份额多于持仓时，只按实际可卖份额折算），因此
/// `cumPnl(最后一日)` 恒等于总览首卡的 `浮动盈亏 + 已实现收益`。
///
/// - 每日盈亏用**当日收盘份额**，与 `summary.dayPnl`（现价 − 昨收）× 持仓份额 同口径
/// - 只有买 / 卖 / 分红参与收益；现金的充值提现不是投资收益
/// - 净值缺失的交易日按**前向填充**，填充后与上一有价日相同时当日盈亏为 0，
///   日历格渲染为**空**而不是 `0`
library;

import '../data/models.dart';
import '../data/nav_models.dart';
import 'calendar_grid.dart';

/// 一只标的的历史净值（按日期升序；股票/ETF 存的是收盘价）
class AssetSeries {
  final Asset asset;
  final List<NavPoint> navs;

  const AssetSeries({required this.asset, required this.navs});
}

/// 日历图的粒度
enum ReturnGranularity { day, month, year }

extension ReturnGranularityX on ReturnGranularity {
  String get label => switch (this) {
        ReturnGranularity.day => '日收益',
        ReturnGranularity.month => '月收益',
        ReturnGranularity.year => '年收益',
      };
}

/// 日历 / 网格里的一格
class PnlCell {
  /// 主标签：日视图是 `11`，月视图是 `9月`，年视图是 `2026`
  final String label;

  /// 次级标签（暂未使用，留给后续扩展）
  final String sub;

  /// 该格盈亏；`null` = 该期间没有净值数据 → 只显示标签、不显示数字
  final double? amount;

  const PnlCell({required this.label, this.sub = '', this.amount});

  bool get hasAmount => amount != null;
}

/// 序列上的一天
class DailyPoint {
  final DateTime date;

  /// 当日盈亏（金额）
  final double dayPnl;

  /// 累计盈亏 = 持仓市值 + 已收回 − 累计投入
  final double cumPnl;

  /// 累计收益率（%）；从未投入过时为 null
  final double? cumPct;

  const DailyPoint({
    required this.date,
    required this.dayPnl,
    required this.cumPnl,
    this.cumPct,
  });
}

/// 区间收益率曲线上的一个点
class ReturnPoint {
  final DateTime date;

  /// 相对区间起点的累计收益率（%）
  final double pct;

  const ReturnPoint({required this.date, required this.pct});
}

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 某只标的在逐日推进过程中的运行状态
class _AssetWalker {
  final AssetSeries series;

  /// 已按日期升序排好的净值
  ///
  /// **不能信任调用方传进来的顺序**：下面用双指针扫净值，一旦乱序就会静默算错
  /// （错得很隐蔽，因为数字看起来仍然「像那么回事」）。所以这里统一排一次。
  final List<NavPoint> navs;

  final List<Txn> txns;
  int txnPtr = 0;
  int navPtr = 0;

  double shares = 0;
  double cost = 0;
  double invested = 0;
  double returned = 0;

  /// 最近一条 ≤ 当日的净值
  double? nav;

  /// 上一条净值（严格早于当日）
  double? prevNav;

  /// 当前这条净值自己的日期（用来判断「当日到底有没有新净值」）
  DateTime? navDay;

  /// 本次 [advanceTo] 有没有吃到新净值
  ///
  /// 判断依据只能是这个：只看 `nav` / `prevNav` 的话，没有新净值的标的会一直
  /// 保留上一对的差值，于是**把上一天的涨跌又算一遍**。一只标的少一天净值
  /// （周末、QDII 滞后、停牌）就会凭空多出一笔当天收益。
  bool gotNewNav = false;

  _AssetWalker(this.series, List<Txn> allTxns)
      : txns = List<Txn>.from(allTxns)
          ..sort((a, b) => a.date.compareTo(b.date)),
        navs = List<NavPoint>.from(series.navs)
          ..sort((a, b) => a.date.compareTo(b.date));

  /// 推进到 [d]（含）：先吃掉所有 ≤ d 的交易，再吃掉所有 ≤ d 的净值
  void advanceTo(DateTime d) {
    final cut = dayOnly(d);
    gotNewNav = false;
    while (txnPtr < txns.length &&
        !dayOnly(txns[txnPtr].date).isAfter(cut)) {
      final t = txns[txnPtr++];
      switch (t.type) {
        case TxnType.buy:
          invested += t.amount + t.fee;
          shares += t.shares;
          cost += t.amount + t.fee;
          break;
        case TxnType.sell:
          // 与 buildPositions 一致：超卖时只折算实际可卖份额
          final avg = shares > 1e-9 ? cost / shares : 0.0;
          final sold = t.shares < shares ? t.shares : shares;
          final ratio = t.shares > 1e-9 ? sold / t.shares : 0.0;
          returned += (t.amount - t.fee) * ratio;
          cost -= avg * sold;
          shares -= sold;
          break;
        case TxnType.dividend:
          // 分红不改变份额，只进「已收回」
          returned += t.amount;
          break;
      }
    }

    final navs = this.navs;
    while (navPtr < navs.length &&
        !dayOnly(_parseDay(navs[navPtr].date)).isAfter(cut)) {
      prevNav = nav;
      nav = navs[navPtr].nav;
      navDay = _parseDay(navs[navPtr].date);
      gotNewNav = true;
      navPtr++;
    }
  }
}

DateTime _parseDay(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? DateTime(1970) : dayOnly(d);
}

/// 逐日构建组合序列
///
/// [start] / [end] 均为**含**边界。返回按日期升序，只包含至少有一只标的
/// 在那天有净值的日子（周末与停牌日不产生点，日历里自然是空格）。
List<DailyPoint> buildDailySeries({
  required List<AssetSeries> assets,
  required List<Txn> txns,
  int? accountId,
  required DateTime start,
  required DateTime end,
}) {
  if (assets.isEmpty) return const [];
  final lo = dayOnly(start);
  final hi = dayOnly(end);
  if (hi.isBefore(lo)) return const [];

  // 1) 收集窗口内所有「有净值」的日期，作为序列的时间轴
  final daySet = <DateTime>{};
  for (final a in assets) {
    for (final p in a.navs) {
      final d = _parseDay(p.date);
      if (d.isBefore(lo) || d.isAfter(hi)) continue;
      daySet.add(d);
    }
  }
  if (daySet.isEmpty) return const [];
  final days = daySet.toList()..sort();

  // 2) 交易按账户过滤后按标的分组
  final byAssetId = <int, List<Txn>>{};
  for (final t in txns) {
    if (accountId != null && t.accountId != accountId) continue;
    byAssetId.putIfAbsent(t.assetId, () => <Txn>[]).add(t);
  }

  final walkers = <_AssetWalker>[];
  for (final a in assets) {
    final id = a.asset.id;
    if (id == null) continue;
    walkers.add(_AssetWalker(a, byAssetId[id] ?? const <Txn>[]));
  }
  if (walkers.isEmpty) return const [];

  // 3) 逐日推进
  final out = <DailyPoint>[];
  for (final d in days) {
    var value = 0.0;
    var dayPnl = 0.0;
    var invested = 0.0;
    var returned = 0.0;

    for (final w in walkers) {
      w.advanceTo(d);
      invested += w.invested;
      returned += w.returned;

      final nav = w.nav;
      if (nav == null) continue;
      if (w.shares.abs() > 1e-9) value += w.shares * nav;

      // 第一条净值没有「上一价」，当日盈亏无从谈起，记 0；
      // 当日**没有新净值**（周末、QDII 滞后、停牌）也只记 0 —— 否则会把
      // 上一次的涨跌在本日再算一遍
      final prev = w.prevNav;
      if (w.gotNewNav &&
          prev != null &&
          w.shares.abs() > 1e-9 &&
          w.navDay == d) {
        dayPnl += w.shares * (nav - prev);
      }
    }

    final cumPnl = value + returned - invested;
    out.add(DailyPoint(
      date: d,
      dayPnl: dayPnl,
      cumPnl: cumPnl,
      cumPct: invested > 1e-9 ? cumPnl / invested * 100 : null,
    ));
  }
  return out;
}

/// 日粒度：该月的网格（42 格，与日期选择器同规则，周日起始）
List<PnlCell> cellsForMonth(List<DailyPoint> series, int year, int month) {
  final byDay = <int, double>{};
  for (final p in series) {
    if (p.date.year == year && p.date.month == month) {
      byDay[p.date.day] = p.dayPnl;
    }
  }
  return [
    for (final d in monthGrid(year, month))
      d == null
          ? const PnlCell(label: '')
          : PnlCell(label: '$d', amount: byDay[d]),
  ];
}

/// 月粒度：该年 12 格
List<PnlCell> cellsForYear(List<DailyPoint> series, int year) {
  final byMonth = <int, double>{};
  for (final p in series) {
    if (p.date.year != year) continue;
    byMonth[p.date.month] = (byMonth[p.date.month] ?? 0) + p.dayPnl;
  }
  return [
    for (var m = 1; m <= 12; m++)
      PnlCell(label: '$m月', amount: byMonth[m]),
  ];
}

/// 年粒度：序列覆盖到的每一年
List<PnlCell> cellsForYears(List<DailyPoint> series) {
  if (series.isEmpty) return const [];
  final byYear = <int, double>{};
  for (final p in series) {
    byYear[p.date.year] = (byYear[p.date.year] ?? 0) + p.dayPnl;
  }
  final years = byYear.keys.toList()..sort();
  return [
    for (final y in years) PnlCell(label: '$y', amount: byYear[y]),
  ];
}

/// 该粒度的数据是否为空（用来决定是否展示空态提示）
bool cellsAllEmpty(List<PnlCell> cells) =>
    cells.every((c) => c.amount == null);

/// 网格里所有格子的盈亏之和
double sumCells(List<PnlCell> cells) =>
    cells.fold<double>(0, (a, c) => a + (c.amount ?? 0));

/// 当前视图各格盈亏之和 —— 日历图上那行「累计收益」用的就是它
///
/// 整屏都没有数据时返回 `null`：该显示 `--` 而不是 `¥0.00`，
/// 「这个月根本没有净值数据」和「这个月盈亏恰好为 0」不是一回事。
double? periodPnlOf(List<PnlCell> cells) =>
    cellsAllEmpty(cells) ? null : sumCells(cells);

/// 区间累计收益率曲线（用于趋势图）
///
/// 起点归零：在 [start] 处补一个 `pct = 0` 的锚点，第一条真实净值日就带上
/// 当天盈亏，因此**阶段收益 = 最后一个点**，不会漏掉区间第一天。
///
/// 若有更早的历史，基准取 `start` **之前**最后一点的累计收益率，
/// 这样跨区间边界的收益不会被算进来。
List<ReturnPoint> windowReturnSeries(
  List<DailyPoint> series,
  DateTime start,
  DateTime end,
) {
  if (series.isEmpty) return const [];
  final lo = dayOnly(start);
  final hi = dayOnly(end);

  double? base;
  for (final p in series) {
    if (p.date.isBefore(lo)) {
      if (p.cumPct != null) base = p.cumPct;
    } else {
      break;
    }
  }

  final out = <ReturnPoint>[ReturnPoint(date: lo, pct: 0)];
  for (final p in series) {
    if (p.date.isBefore(lo) || p.date.isAfter(hi)) continue;
    final pct = p.cumPct;
    if (pct == null) continue;
    out.add(ReturnPoint(date: p.date, pct: pct - (base ?? 0)));
  }
  return out;
}

/// 序列里最后一天（用来取「当前」累计收益）
DailyPoint? lastPoint(List<DailyPoint> series) =>
    series.isEmpty ? null : series.last;

/// [asOf] 收盘时的持仓市值与总成本
///
/// 缺历史净值的标的退回用**平均成本单价**估值，其代码记入 `missingNav`，
/// 界面据此加「含成本估值」脚注——宁可标注也不静默算成 0。
({double value, double cost, List<String> missingNav}) holdingValueOn({
  required List<AssetSeries> assets,
  required List<Txn> txns,
  int? accountId,
  required DateTime asOf,
}) {
  final byAssetId = <int, List<Txn>>{};
  for (final t in txns) {
    if (accountId != null && t.accountId != accountId) continue;
    byAssetId.putIfAbsent(t.assetId, () => <Txn>[]).add(t);
  }

  var value = 0.0;
  var cost = 0.0;
  final missing = <String>[];
  for (final a in assets) {
    final id = a.asset.id;
    if (id == null) continue;
    final w = _AssetWalker(a, byAssetId[id] ?? const <Txn>[]);
    w.advanceTo(asOf);
    if (w.shares.abs() <= 1e-9) continue;

    // 数学上成本恒 >= 0，负值只可能是浮点误差
    final c = (w.cost < 0 || w.cost.abs() < 1e-9) ? 0.0 : w.cost;
    cost += c;

    final nav = w.nav;
    if (nav != null && nav > 0) {
      value += w.shares * nav;
    } else {
      value += c;
      missing.add(a.asset.code);
    }
  }
  return (value: value, cost: cost, missingNav: missing);
}

/// 在 [start, end] 内按标的汇总「买入含手续费」「卖出净额」「现金分红」
///
/// 与 [buildDailySeries] 共用超卖折算规则，保证两边口径一致。
///
/// 额外返回 [redeemLedger]：**不做超卖折算**的卖出净额，专供与现金账本对账
/// （现金行是全额，用折算过的数去比会误报"现金流水不完整"）。
({double invest, double redeem, double dividend, double redeemLedger})
    flowTotals({
  required List<Txn> txns,
  int? accountId,
  required DateTime start,
  required DateTime end,
}) {
  final lo = dayOnly(start);
  final hi = dayOnly(end);

  // 必须先按标的分组、按时间升序，才能正确折算超卖
  final grouped = <int, List<Txn>>{};
  for (final t in txns) {
    if (accountId != null && t.accountId != accountId) continue;
    grouped.putIfAbsent(t.assetId, () => <Txn>[]).add(t);
  }

  var invest = 0.0;
  var redeem = 0.0;
  var dividend = 0.0;
  var redeemLedger = 0.0;
  for (final list in grouped.values) {
    list.sort((a, b) => a.date.compareTo(b.date));
    var shares = 0.0;
    for (final t in list) {
      final inWindow = !dayOnly(t.date).isBefore(lo) &&
          !dayOnly(t.date).isAfter(hi);
      switch (t.type) {
        case TxnType.buy:
          // 不动现金的买入（成本调整 / 红利再投）不计入「投入金额」，
          // 否则会和现金账本对不上、误报「买入没有对应的现金扣款」
          if (inWindow && !t.isCashless) invest += t.amount + t.fee;
          shares += t.shares;
          break;
        case TxnType.sell:
          final sold = t.shares < shares ? t.shares : shares;
          final ratio = t.shares > 1e-9 ? sold / t.shares : 0.0;
          if (inWindow && !t.isCashless) {
            redeem += (t.amount - t.fee) * ratio;
            // 联动现金行记的是全额 amount−fee，对账要用这个
            redeemLedger += t.amount - t.fee;
          }
          shares -= sold;
          break;
        case TxnType.dividend:
          if (inWindow) dividend += t.amount;
          break;
      }
    }
  }
  return (
    invest: invest,
    redeem: redeem,
    dividend: dividend,
    redeemLedger: redeemLedger,
  );
}
