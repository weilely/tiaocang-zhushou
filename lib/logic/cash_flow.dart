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

  /// 期间卖出净额，**不做超卖折算**（= 每笔 `amount − fee` 全额相加），
  /// 专门用来与 [cashRedeem] 对账。
  ///
  /// 为什么要单独留一个：图上那个 [redeemAmount] 会按「当时账面上有多少份额」
  /// 做超卖折算（与日线序列口径一致），而现金行是**全额**的 —— 两边口径不同，
  /// 直接相减会凭空造出一个假缺口，误报「现金流水不完整」。
  final double redeemLedger;

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
    this.redeemLedger = 0,
    this.beginMissingNav = const [],
    this.endMissingNav = const [],
  });

  /// 期间的买入没有在现金账本里扣款 → 现金流水不完整
  ///
  /// 恒等式①在这种情况下**依然成立**（它只是算术），但那笔买入的钱没被记成
  /// 支出，于是会被当成收益，账户盈亏会明显偏大、与总览的累计收益对不上。
  /// 常见于「早年只补录了交易、没有配套现金流水」的老数据。
  ///
  /// 注意：买入侧没有超卖折算，两边口径天然一致。
  double get investGap => investAmount - cashInvest;

  /// 期间的卖出没有在现金账本里入账。
  ///
  /// **必须用 [redeemLedger]（不折算）而不是 [redeemAmount]**：后者做过超卖
  /// 折算，与现金行的全额口径不同，相减会误报（实测用户数据里买卖两侧差额
  /// 其实都是 0，却因为折算凭空报出 1050.51 的缺口）。
  double get redeemGap => redeemLedger - cashRedeem;

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
/// - **分红** → `dividend`，金额 `成交金额 − 手续费`
///
/// **手续费一律并进现金流**（用户 2026-09-28 的口径：买入 3000 + 费 2.5 → 支出 302.5）。
/// 分红那一格手续费是"渠道扣费之类"（见记一笔页面），以前这里把它漏掉了，
/// 与真正写库的 `_linkCashFor`（它按 `金额 − 费` 写）口径不一致 —— 已对齐。
///
/// **不动现金的流水**（`Txn.isCashless`）：
/// - 「红利再投 / 再投」→ 回一条**金额 0 的 `reinvest` 行**（用户 2026-09-29 选的），
///   份额照加、余额不变，但流水里看得见这笔分红去哪了；
/// - 「成本调整」→ 回 `null`（纯账面调整）。
///
/// 金额为 0 时返回 `null`（不写一条没有意义的流水）—— 唯一的例外是「再投」：
/// 它本来就是 0 元行（金额不算，留着是为了让流水说得清这笔分红去哪了）。
///
/// **所有产生交易的路径都要用它**（手工录入、定投补记、CSV 导入、重建），
/// 否则那笔交易的钱就不会体现在现金余额里 —— 反过来，谁绕开它自己拼一条
/// 现金流水，谁就会把上面这些口径再写错一遍（CSV 导入漏判 `isCashless`
/// 就是这么来的）。
CashTxn? linkedCashTxnFor(Txn t, int? txnId, {String? note}) {
  final n = note ?? '来自${t.type.label}';
  if (t.isCashless) {
    if (!t.isReinvest) return null; // 成本调整：纯账面，不写现金
    return CashTxn(
      accountId: t.accountId,
      type: CashType.reinvest,
      amount: 0,
      date: t.date,
      note: n,
      srcTxnId: txnId,
    );
  }
  final (type, amount) = switch (t.type) {
    TxnType.buy => (CashType.invest, -(t.amount + t.fee)),
    TxnType.sell => (CashType.redeem, t.amount - t.fee),
    TxnType.dividend => (CashType.dividend, t.amount - t.fee),
  };
  if (amount == 0) return null;
  return CashTxn(
    accountId: t.accountId,
    type: type,
    amount: amount,
    date: t.date,
    note: n,
    srcTxnId: txnId,
  );
}

/// 现金流水行的**种类**：列表抬头与筛选共用这一处判定。
///
/// 只有「定投」是算出来的：它是买入里带定投标记的那些（看影子交易的备注，
/// 老数据的现金行备注常常没有「定投」）。其余一律就是存库的 `type`。
String cashRowKind(CashTxn c, Txn? linked) {
  if (c.type == CashType.invest && (linked?.note ?? c.note).contains('定投')) {
    return 'dca';
  }
  return c.type;
}

/// 种类的显示名（「全部」在筛选条里用，别处用不到）
String cashKindLabel(String kind) => switch (kind) {
      'all' => '全部',
      'dca' => '定投',
      _ => CashType.label(kind),
    };

/// 一笔交易的**动作词**：`买入 / 卖出 / 分红 / 定投 / 再投`。
///
/// 交易记录列表的抬头、现金流水行、编辑页顶部、现金备注全用这一套词
/// （用户 2026-09-29：「统一口径」「抬头也和现金流水一样」）—— 只有这一处判定：
/// 红利再投（`Txn.isReinvest`）叫「再投」、备注含「定投」的买入叫「定投」。
String txnActionWord(Txn t) => switch (t.type) {
      TxnType.buy => t.isReinvest
          ? '再投'
          : (t.note.contains('定投') ? '定投' : '买入'),
      TxnType.sell => '卖出',
      TxnType.dividend => '分红',
    };

/// 现金**收益**：账户 → [当月, 累计]
///
/// **只算 `income`**（货币基金/国债逆回购的利息）。
/// 现金分红是「分红入账」、不是收益 —— 用户 2026-09-29 的原话：
/// 「现金分红应该记为分红入账」。以前这里把 `dividend` 也算进收益，
/// 同一页的年份抬头却只算 `income`，一页里两个「收益」口径都不一样。
Map<int, List<double>> cashIncomeOf(List<CashTxn> list, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final out = <int, List<double>>{};
  for (final t in list) {
    if (t.type != CashType.income) continue;
    final v = out.putIfAbsent(t.accountId, () => [0, 0]);
    v[1] += t.amount;
    if (t.date.year == at.year && t.date.month == at.month) v[0] += t.amount;
  }
  return out;
}

/// 现金分红合计（只算 `dividend`，不含「再投」那条 0 元行）
double cashDividendTotal(List<CashTxn> list, {int? accountId}) {
  var sum = 0.0;
  for (final t in list) {
    if (t.type != CashType.dividend) continue;
    if (accountId != null && t.accountId != accountId) continue;
    sum += t.amount;
  }
  return sum;
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
      case CashType.dividend:
        // 现金分红**不并进 `cashIncome`**（那只算货币基金/逆回购的利息，
        // 用户 2026-09-29 定），也**不并进 `dividend`** —— 那个字段取的是
        // 交易侧（`flowTotals`），并进来会算两遍。分红已经含在下面的
        // `endCash` 里，而余额是恒等式①的一部分。
        break;
      case CashType.reinvest:
        // 红利再投金额恒为 0：只在流水里留个痕迹，余额与统计都不受影响。
        break;
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
    redeemLedger: flows.redeemLedger,
    beginMissingNav: beginSnap.missingNav,
    endMissingNav: endSnap.missingNav,
  );
}
