/// 分红/拆分核对（**只诊断，不写库**）
///
/// 用户 2026-09-22 的原话：「分红怎么核对，如果中途更改了红利再投或现金分红，
/// 只能核对历史净值和累计净值，你先把逻辑说给我听」→ 定下的路子是：
/// 先只用**净值 + 累计净值**把「哪一天、每份分了多少钱」核实出来（两个独立来源），
/// 再拿它去对他的账本（现金分红 / 红利再投 / 什么都没记）。
///
/// 两个核心事实（都用他库里的真实数据验过）：
/// - **分红**：`Δ(累计净值 − 单位净值) = 每份分红`。024564 实测 ΔD 0.010 → 0.018，
///   与净值文字「每份派现金0.01 / 0.008元」、同花顺「每10份 0.10 / 0.08 元」三方一致。
/// - **拆分**：`ΔD = (折算系数 − 1) × 折算后单位净值`。163402 实测 ΔD 3.0939、净值 1.0
///   → 反推系数 3.9939，与文字「每份基金份额折算3.993900918份」一致。
///
/// ⚠️ **两者都会让 ΔD 跳增**（拆分跳得更大），所以：
/// **定性一律以净值行里自带的文字为准，ΔD 只用来算金额 / 交叉验证。**
///
/// 口径约定：
/// - 有没有份看**除息日前一交易日收盘的份额**（除息日当天才买入的不算），
///   同时记下"除息日当天有没有交易"，界面上要提示（份额口径可能受影响）；
/// - 红利再投的份额 = 应得金额 ÷ **除息日单位净值**（不是累计净值）；
/// - 税用**税前**（公募对个人投资者暂免红利税，税后列是机构口径）。
library;

import 'dart:math' as math;

import '../data/models.dart';
import '../data/nav_models.dart';
import 'dividend.dart';

/// 从「拆分」原文里抠出折算系数（份/份）；不是拆分返回 null
double? splitFactor(String text) {
  final t = text.trim();
  if (t.isEmpty || !t.contains('折算')) return null;
  final m = RegExp(r'折算\s*([0-9]+(?:\.[0-9]+)?)\s*份').firstMatch(t);
  if (m == null) return null;
  final v = double.tryParse(m.group(1) ?? '');
  return (v == null || v <= 0) ? null : v;
}

/// 净值里能看见的一次分红 / 拆分
class DividendEvent {
  final String code;

  /// 除息日（净值下调那天，就是净值行上的日期）
  final String date;

  /// 拆分（份额折算）为 true，分红为 false
  final bool isSplit;

  /// 分红 = 每份派现（元/份）；拆分 = 折算系数（份）
  final double perShare;

  /// 当日单位净值
  final double nav;

  /// 当日 (累计净值 − 单位净值) 相对上一条的增量；没有累计净值时为 null
  final double? deltaDiff;

  /// 净值行里的原文（定性依据）
  final String text;

  const DividendEvent({
    required this.code,
    required this.date,
    required this.isSplit,
    required this.perShare,
    required this.nav,
    required this.deltaDiff,
    required this.text,
  });

  /// 按文字推出来的「ΔD 应该是多少」
  double get expectDelta => isSplit ? (perShare - 1) * nav : perShare;

  /// 文字与累计净值是否自洽；null = 没有累计净值（ETF/股票那种），验不了
  bool? get consistent {
    final d = deltaDiff;
    if (d == null) return null;
    return (d - expectDelta).abs() <= tolerance;
  }

  /// 金额容差：半分钱、或千分之五
  static const double tolerance = 0.005;
}

/// 从净值序列里提炼分红/拆分事件（[points] 需按日期升序）
///
/// 认不出类型的文字**直接跳过**（宁可漏，也不猜）。
List<DividendEvent> extractDividendEvents(String code, List<NavPoint> points) {
  final out = <DividendEvent>[];
  double? prevDiff;
  for (final p in points) {
    final diff = p.accNav > 0 ? p.accNav - p.nav : null;
    if (!p.hasDividend) {
      if (diff != null) prevDiff = diff;
      continue;
    }
    final per = perShareDividend(p.dividend);
    final k = splitFactor(p.dividend);
    if (per == null && k == null) {
      if (diff != null) prevDiff = diff;
      continue;
    }
    final delta = (diff != null && prevDiff != null) ? diff - prevDiff : null;
    out.add(DividendEvent(
      code: code,
      date: p.date,
      isSplit: per == null,
      perShare: per ?? k!,
      nav: p.nav,
      deltaDiff: delta,
      text: p.dividend,
    ));
    if (diff != null) prevDiff = diff;
  }
  return out;
}

/// 对账结论
enum DivCheckStatus {
  /// 账本里有对应的**现金分红**
  cashRecorded,

  /// 账本里有对应的**红利再投**
  reinvestRecorded,

  /// 该记而没记（会给出该补的金额/份额）
  missing,

  /// 记了但对不上（金额或份额差得多）
  mismatch,

  /// 那天还没持有 / 已经清仓 —— 与你无关
  notHeld,

  /// **账本份额为负**（卖得比买的多）
  ///
  /// 这几乎总是"前面某次红利再投没把份额记进去"的症状：少记了份额，
  /// 后来把实际持有的全部卖出，账本就会短缺那么多份（实测用户那 4 只基金
  /// 就是各少 305.07 / 287.56 / 186.81 / 25.57 份）。**这种要靠先补前面的缺记才能算清。**
  ledgerShort,

  /// 拆分（份额折算）：不是钱的事，只提示份额应变成多少
  split,
}

/// 一次事件对一个账户的对账结果
class DivCheckRow {
  final DividendEvent event;
  final int accountId;
  final int assetId;
  final String assetName;
  final String code;
  final String accountName;

  /// 除息日前一交易日收盘的持有份额（决定有没有份）
  final double shares;

  /// 除息日当天还有交易 → 份额口径可能受影响，界面上要提示
  final bool tradedOnExDate;

  /// 应得金额（分红）
  final double expectAmount;

  /// 应得份额（再投；现金分红不用）
  final double expectShares;

  /// 账本里找到的那笔
  final double foundAmount;
  final double foundShares;
  final String foundNote;

  final DivCheckStatus status;

  /// 当前分红方式；[modeApplies] = 这次分红在生效日之后（否则方式只是"建议"）
  final String mode;
  final bool modeApplies;

  const DivCheckRow({
    required this.event,
    required this.accountId,
    required this.assetId,
    required this.assetName,
    required this.code,
    required this.accountName,
    required this.shares,
    required this.tradedOnExDate,
    required this.expectAmount,
    required this.expectShares,
    required this.foundAmount,
    required this.foundShares,
    required this.foundNote,
    required this.status,
    required this.mode,
    required this.modeApplies,
  });

  String get date => event.date;
  bool get isSplit => event.isSplit;
  double get perShare => event.perShare;

  /// 建议补记方式：只在生效日之后才敢按设置建议；之前留空（历史方式未知）
  String get suggestedMode => modeApplies ? mode : '';
}

/// 金额/份额是否"对得上"：绝对容差 0.02，或相对容差 0.5%
bool closeEnough(double a, double b) {
  final diff = (a - b).abs();
  return diff <= 0.02 || diff <= math.max(a.abs(), b.abs()) * 0.005;
}

/// 值得补记的最小金额（元）
///
/// 低于这个数不列、也不补：卖出后剩下的零头份额（如 0.9 份）会造出"1 分钱分红",
/// 补进账本只会制造噪声。
const double kMinFixAmount = 1.0;

/// 补记时该用哪种方式（用户 2026-09-22 拍板："**按推荐方式补记**"）
///
/// - 这次分红**在分红方式生效日之后** → 就用设置里那个方式（他明确定过的）
/// - 否则一律 **红利再投**：依据是他自己账本里那 15 笔手记「再投」
///   （说明他历史上就是按再投处理的），而且再投**不动现金、只补份额**，
///   正好修掉"份额短缺 → 卖超 → 假警告"这个真问题。
String recommendedModeFor(DivCheckRow row) {
  if (row.modeApplies && DividendMode.isValid(row.mode)) return row.mode;
  return DividendMode.reinvest;
}

/// 把一只标的（某账户）的净值事件对到账本上（**纯函数，不写库**）
List<DivCheckRow> checkDividends({
  required String code,
  required String assetName,
  required String accountName,
  required int accountId,
  required int assetId,
  required List<NavPoint> navs,
  required List<Txn> txns,
  String mode = '',
  DateTime? modeFrom,

  /// 分红到账/再投可能延后，这这段窗口内找痕迹
  int windowDays = 45,
}) {
  final out = <DivCheckRow>[];
  for (final e in extractDividendEvents(code, navs)) {
    final d = DateTime.tryParse(e.date);
    if (d == null) continue;

    var before = 0.0; // 除息日**之前**的份额（真正决定有没有份）
    var through = 0.0; // 含除息日当天的份额（用来判断当天有没有交易）
    for (final t in txns) {
      final delta = switch (t.type) {
        TxnType.buy => t.shares,
        TxnType.sell => -t.shares,
        TxnType.dividend => 0.0,
      };
      if (t.date.isBefore(_dayStart(d))) {
        before += delta;
        through += delta;
      } else if (t.date.isBefore(_dayStart(d).add(const Duration(days: 1)))) {
        through += delta;
      }
    }
    final tradedToday = (through - before).abs() > 1e-9;
    final applies = modeFrom != null && !d.isBefore(_dayStart(modeFrom));

    DivCheckRow row({
      required DivCheckStatus status,
      double expectAmount = 0,
      double expectShares = 0,
      double foundAmount = 0,
      double foundShares = 0,
      String foundNote = '',
    }) =>
        DivCheckRow(
          event: e,
          accountId: accountId,
          assetId: assetId,
          assetName: assetName,
          code: code,
          accountName: accountName,
          shares: before,
          tradedOnExDate: tradedToday,
          expectAmount: expectAmount,
          expectShares: expectShares,
          foundAmount: foundAmount,
          foundShares: foundShares,
          foundNote: foundNote,
          status: status,
          mode: mode,
          modeApplies: applies,
        );

    if (before < -1e-6) {
      // 残份额噪声（|份额| 不到 1 股）：卖出后剩下的零头，多半是份额取整留下的，
      // 列出来只会干扰（应得金额也就几分钱）—— 直接不列。
      if (before > -1) continue;
      // 账本份额为负 = 卖得比买的多 —— 典型是前面的红利再投没记份额，
      // 这种"应得多少"根本算不出来（份额本身是错的），只能先补前面的缺记。
      out.add(row(status: DivCheckStatus.ledgerShort));
      continue;
    }
    if (before <= 1e-6) {
      out.add(row(status: DivCheckStatus.notHeld));
      continue;
    }

    // 残份额（比如卖出后剩 0.9 份）会造出分币级的分红：列出来只是噪声，
    // 补进账本更没意义 —— 直接不列（阈值见 [kMinFixAmount]）。
    if (!e.isSplit && e.perShare * before < kMinFixAmount) continue;

    if (e.isSplit) {
      // 拆分不是钱的事：份额应变成 shares × 系数
      out.add(row(status: DivCheckStatus.split,
          expectShares: before * e.perShare));
      continue;
    }

    final expectAmount = e.perShare * before;
    final expectShares = e.nav > 0 ? expectAmount / e.nav : 0.0;

    // 在窗口里找痕迹：优先认「红利再投」的 cashless 买入，其次认现金分红
    final lo = _dayStart(d).subtract(const Duration(days: 3));
    final hi = _dayStart(d).add(Duration(days: windowDays));
    Txn? rein;
    Txn? cash;
    for (final t in txns) {
      if (t.date.isBefore(lo) || t.date.isAfter(hi)) continue;
      if (rein == null &&
          t.isCashless &&
          t.note.startsWith(Txn.reinvestNote)) {
        rein = t;
      }
      if (cash == null && t.type == TxnType.dividend) cash = t;
    }

    if (rein != null) {
      final ok = closeEnough(rein.amount, expectAmount) ||
          closeEnough(rein.shares, expectShares);
      out.add(row(
        status: ok ? DivCheckStatus.reinvestRecorded : DivCheckStatus.mismatch,
        expectAmount: expectAmount,
        expectShares: expectShares,
        foundAmount: rein.amount,
        foundShares: rein.shares,
        foundNote: rein.note,
      ));
      continue;
    }
    if (cash != null) {
      final ok = closeEnough(cash.amount, expectAmount);
      out.add(row(
        status: ok ? DivCheckStatus.cashRecorded : DivCheckStatus.mismatch,
        expectAmount: expectAmount,
        expectShares: expectShares,
        foundAmount: cash.amount,
        foundNote: cash.note,
      ));
      continue;
    }
    out.add(row(
      status: DivCheckStatus.missing,
      expectAmount: expectAmount,
      expectShares: expectShares,
    ));
  }
  return out;
}

DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
