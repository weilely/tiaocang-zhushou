import '../data/models.dart';
import '../data/nav_models.dart';
import 'range_preset.dart';
import 'returns_calendar.dart';

/// 资金流清单：把所选区间内的「钱」算成一组**总量**，而不是一串流水。
///
/// ## 口径（两条独立算式必须同时成立）
///
/// ```
/// ① 期末资产 = 期初资产 + 净流入 + 账户盈亏          ← 主恒等式（账户盈亏取残差）
/// ② 账户盈亏 = Δ持仓市值 − 投入金额 + 赎回金额
///              + 现金分红 + 现金生息 + 现金调整       ← 独立复算（交叉校验）
/// ```
///
/// 其中：
/// ```
/// 期初资产 = 期初持仓市值 + 期初现金余额
/// 期末资产 = 期末持仓市值 + 期末现金余额
/// 净流入   = 充值 − 提现                    （负数即净流出）
/// 投入金额 = Σ (买入金额 + 手续费)          ← 与 Portfolio 的 invested 同口径
/// 赎回金额 = Σ (卖出金额 − 手续费)          ← 与 Portfolio 的 returned 卖出部分同口径
/// 现金分红 = Σ 分红入账
/// ```
///
/// 现金余额直接取现金账本（`Σ cash_txns.amount`），它已经包含了分红与卖出回款
/// （这两者由 `AppState.saveTxnWithCash` 联动写入），因此主恒等式**按构造成立**；
/// 算式②是用交易与现金流水**另外算一遍**，用来暴露口径写错。
///
/// 唯一的例外是**超卖**（录入的卖出份额大于持仓）：`Portfolio` 会按可卖份额折算，
/// 而现金联动记的是全额，此时②会有差额——这属于录入错误，界面不为此做掩饰。
class CashFlowStatement {
  final DateRange range;

  final double beginHolding;
  final double beginCash;
  final double endHolding;
  final double endCash;

  /// 期间充值 / 提现（外部现金流）
  final double deposit;
  final double withdraw;

  /// 期间买入含手续费 / 卖出净额（投资流）
  final double investAmount;
  final double redeemAmount;

  /// 期间现金分红
  final double dividend;

  /// 期间现金生息（货币基金 / 国债逆回购）
  final double cashIncome;

  /// 期间现金调整（手工校正）
  final double cashAdjust;

  /// 现金账本里「买入扣款」的合计（正数），用于自检
  final double cashInvest;

  /// 现金账本里「卖出入账」的合计，用于自检
  final double cashRedeem;

  /// 期初持仓里缺历史净值、退回成本单价估值的标的代码
  final List<String> beginMissingNav;

  /// 期末持仓里缺历史净值、退回成本单价估值的标的代码
  final List<String> endMissingNav;

  const CashFlowStatement({
    required this.range,
    required this.beginHolding,
    required this.beginCash,
    required this.endHolding,
    required this.endCash,
    required this.deposit,
    required this.withdraw,
    required this.investAmount,
    required this.redeemAmount,
    required this.dividend,
    required this.cashIncome,
    required this.cashAdjust,
    this.cashInvest = 0,
    this.cashRedeem = 0,
    this.beginMissingNav = const [],
    this.endMissingNav = const [],
  });

  /// 期间的买入没有在现金账本里扣款 → 现金流水不完整
  ///
  /// 恒等式①在这种情况下**依然成立**（它只是算术），但那笔买入的钱没被记成
  /// 支出，于是会被当成收益，账户盈亏会明显偏大、与总览的累计收益对不上。
  /// 常见于「早年只补录了交易、没有配套现金流水」的老数据。
  double get investGap => investAmount - cashInvest;

  /// 期间的卖出没有在现金账本里入账
  double get redeemGap => redeemAmount - cashRedeem;

  bool get ledgerIncomplete =>
      investGap.abs() > 0.01 || redeemGap.abs() > 0.01;

  double get beginAssets => beginHolding + beginCash;
  double get endAssets => endHolding + endCash;

  /// 净流入（负数即净流出）
  double get netFlow => deposit - withdraw;

  /// 净流出金额（净流入时返回 0，供界面选标签用）
  bool get isOutflow => netFlow < 0;

  String get netFlowLabel => isOutflow ? '净流出' : '净流入';

  /// 账户盈亏：**取主恒等式的残差**，保证①无条件成立
  double get pnl => endAssets - beginAssets - netFlow;

  /// 算式②的独立复算值，仅供自检与测试
  double get pnlCrossCheck =>
      (endHolding - beginHolding) -
      investAmount +
      redeemAmount +
      dividend +
      cashIncome +
      cashAdjust;

  /// 期间完全没有记录（判断空态）
  bool get isEmpty =>
      beginAssets.abs() < 1e-9 &&
      endAssets.abs() < 1e-9 &&
      deposit.abs() < 1e-9 &&
      withdraw.abs() < 1e-9 &&
      investAmount.abs() < 1e-9 &&
      redeemAmount.abs() < 1e-9;

  /// 主恒等式的残差（应恒为 0，测试用）
  double get identityGap => endAssets - (beginAssets + netFlow + pnl);
}

/// 一笔交易联动生成的那条现金流水
///
/// 符号约定（与 `Txn.netCash` 一致）：
/// - **买入** → `invest`，金额 `−(成交金额 + 手续费)`
/// - **卖出** → `redeem`，金额 `成交金额 − 手续费`
/// - **分红** → `dividend`，金额 `成交金额`
///
/// 金额为 0 时返回 `null`（不写一条没有意义的流水）。
///
/// **所有产生交易的路径都要用它**（手工录入、定投补记、CSV 导入），
/// 否则那笔交易的钱就不会体现在现金余额里。
CashTxn? linkedCashTxnFor(Txn t, int txnId) {
  final (type, amount) = switch (t.type) {
    TxnType.buy => (CashType.invest, -(t.amount + t.fee)),
    TxnType.sell => (CashType.redeem, t.amount - t.fee),
    TxnType.dividend => (CashType.dividend, t.amount),
  };
  if (amount == 0) return null;
  return CashTxn(
    accountId: t.accountId,
    type: type,
    amount: amount,
    date: t.date,
    note: '来自${t.type.label}',
    srcTxnId: txnId,
  );
}

/// 构建资金流清单
///
/// [assets] 用于取期初/期末持仓市值（需要历史净值，缺则退回成本单价估值）；
/// [txns] 提供买入/卖出/分红；[cashTxns] 提供充值/提现/生息/调整与现金余额。
CashFlowStatement buildCashFlowStatement({
  required List<AssetSeries> assets,
  required List<Txn> txns,
  required List<CashTxn> cashTxns,
  int? accountId,
  required DateRange range,
}) {
  List<CashTxn> mine() => cashTxns
      .where((c) => accountId == null || c.accountId == accountId)
      .toList();

  final cash = mine();

  final beginSnap = holdingValueOn(
    assets: assets,
    txns: txns,
    accountId: accountId,
    asOf: range.dayBeforeStart,
  );
  final endSnap = holdingValueOn(
    assets: assets,
    txns: txns,
    accountId: accountId,
    asOf: range.end,
  );

  var beginCash = 0.0;
  var endCash = 0.0;
  var deposit = 0.0;
  var withdraw = 0.0;
  var cashIncome = 0.0;
  var cashAdjust = 0.0;
  var cashInvest = 0.0;
  var cashRedeem = 0.0;

  for (final c in cash) {
    final d = DateTime(c.date.year, c.date.month, c.date.day);
    if (d.isBefore(range.start)) {
      beginCash += c.amount;
      continue;
    }
    if (d.isAfter(range.end)) continue;

    // 区间内
    switch (c.type) {
      case CashType.deposit:
        deposit += c.amount;
      case CashType.withdraw:
        // 提现以负数记录，取绝对值更符合「提现了多少」的直觉
        withdraw += c.amount.abs();
      case CashType.income:
        cashIncome += c.amount;
      case CashType.adjust:
        cashAdjust += c.amount;
      case CashType.invest:
        cashInvest += c.amount.abs();
      case CashType.redeem:
        cashRedeem += c.amount;
    }
    endCash += c.amount;
  }
  // 期末现金 = 期初 + 区间内所有现金流水（含买入扣款/卖出入账/分红）
  endCash += beginCash;

  final flows = flowTotals(
    txns: txns,
    accountId: accountId,
    start: range.start,
    end: range.end,
  );

  return CashFlowStatement(
    range: range,
    beginHolding: beginSnap.value,
    beginCash: beginCash,
    endHolding: endSnap.value,
    endCash: endCash,
    deposit: deposit,
    withdraw: withdraw,
    investAmount: flows.invest,
    redeemAmount: flows.redeem,
    dividend: flows.dividend,
    cashIncome: cashIncome,
    cashAdjust: cashAdjust,
    cashInvest: cashInvest,
    cashRedeem: cashRedeem,
    beginMissingNav: beginSnap.missingNav,
    endMissingNav: endSnap.missingNav,
  );
}
