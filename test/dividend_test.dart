import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/dividend.dart';
import 'package:invest_tracker/logic/range_preset.dart';
import 'package:invest_tracker/logic/cash_flow.dart';
import 'package:invest_tracker/logic/returns_calendar.dart';

/// 分红送配原文解析：只认现金分红，拆分/折算一律不算
void main() {
  group('perShareDividend：解析每份派现金额', () {
    test('实测原文「分红：每份派现金0.03元」→ 0.03', () {
      expect(perShareDividend('分红：每份派现金0.03元'), closeTo(0.03, 1e-9));
      expect(perShareDividend('分红：每份派现金0.11元'), closeTo(0.11, 1e-9));
      expect(perShareDividend('分红：每份派现金0.3元'), closeTo(0.3, 1e-9));
      expect(perShareDividend('分红：每份派现金0.6108元'), closeTo(0.6108, 1e-9));
    });

    test('「每10份派现金X元」要除以 10', () {
      expect(perShareDividend('分红：每10份派现金0.30元'), closeTo(0.03, 1e-9));
      expect(perShareDividend('分红：每10份派现金1.20元'), closeTo(0.12, 1e-9));
    });

    test('拆分 / 折算不是分红 → null', () {
      expect(perShareDividend('拆分：每份基金份额折算3.993900918份'), isNull);
      expect(perShareDividend('折算：每份基金份额折算1.012345678份'), isNull);
    });

    test('空串 / 空白 / 无数字 → null', () {
      expect(perShareDividend(''), isNull);
      expect(perShareDividend('   '), isNull);
      expect(perShareDividend('分红：每份派现金元'), isNull);
    });

    test('0 元 / 负数不当作分红', () {
      expect(perShareDividend('分红：每份派现金0元'), isNull);
    });
  });

  group('DividendMode', () {
    test('标签与合法性', () {
      expect(DividendMode.label(DividendMode.cash), '现金分红');
      expect(DividendMode.label(DividendMode.reinvest), '红利再投');
      expect(DividendMode.label(DividendMode.none), '不自动');
      expect(DividendMode.isValid(DividendMode.cash), isTrue);
      expect(DividendMode.isValid(DividendMode.reinvest), isTrue);
      expect(DividendMode.isValid(DividendMode.none), isFalse);
      expect(DividendMode.isValid('乱填'), isFalse);
    });
  });

  group('不动现金的买入不该计入「投入金额」', () {
    final day = DateTime(2026, 9, 10);

    Txn buy({double amount = 1000, double shares = 100, String note = ''}) =>
        Txn(
          accountId: 1,
          assetId: 1,
          type: TxnType.buy,
          date: day,
          amount: amount,
          shares: shares,
          price: 10,
          note: note,
        );

    ({
      double invest,
      double redeem,
      double dividend,
      double redeemLedger,
    }) totals(List<Txn> list) =>
        flowTotals(txns: list, start: day, end: day);

    test('普通买入照常计入', () {
      expect(totals([buy()]).invest, closeTo(1000, 1e-9));
    });

    test('成本调整不计入（否则现金账本对不上，会误报缺口）', () {
      expect(totals([buy(amount: 45, shares: 0, note: Txn.costAdjustNote)]).invest,
          closeTo(0, 1e-9));
    });

    test('红利再投不计入，但**份额仍要加上**', () {
      final t = buy(shares: 30, note: '${Txn.reinvestNote} 2026-09-10');
      expect(t.isCashless, isTrue);
      expect(totals([t]).invest, closeTo(0, 1e-9));
      // 份额不受影响：后续卖出要能卖到这些份额
      final sold = Txn(
        accountId: 1,
        assetId: 1,
        type: TxnType.sell,
        date: day,
        amount: 300,
        shares: 30,
        price: 10,
      );
      expect(totals([t, sold]).redeem, closeTo(300, 1e-9));
    });

    test('isCashless 只认这两种备注', () {
      expect(buy(note: '').isCashless, isFalse);
      expect(buy(note: '定投').isCashless, isFalse);
      expect(buy(note: Txn.costAdjustNote).isCashless, isTrue);
      expect(buy(note: '${Txn.reinvestNote} 2026-06-30').isCashless, isTrue);
    });
  });

  // 用户真实数据（2026-09-20）暴露的假阳性：卖出侧做过超卖折算，现金行是全额，
  // 两边一减凭空报出 1050.51 的「现金流水不完整」。这里把这条守死。
  group('超卖折算不能让「卖出 vs 现金」对账误报', () {
    final d1 = DateTime(2026, 9, 1);
    final d2 = DateTime(2026, 9, 2);

    Txn sell({required double amount, required double shares, double fee = 0}) =>
        Txn(
          accountId: 1,
          assetId: 1,
          type: TxnType.sell,
          date: d2,
          amount: amount,
          shares: shares,
          price: 1,
          fee: fee,
        );

    Txn buy({required double shares}) => Txn(
          accountId: 1,
          assetId: 1,
          type: TxnType.buy,
          date: d1,
          amount: shares,
          shares: shares,
          price: 1,
        );

    test('卖出份额超过账上持有 → 图上的赎回金额打折，但对账口径不打折', () {
      // 只买过 100 份，却卖了 200 份（早年漏录买入的典型情形）
      final list = [buy(shares: 100), sell(amount: 20000, shares: 200)];
      final f = flowTotals(txns: list, start: d1, end: d2);
      expect(f.redeem, closeTo(10000, 1e-9), reason: '图上按 100/200 折算');
      expect(f.redeemLedger, closeTo(20000, 1e-9),
          reason: '对账要用全额 —— 联动现金行记的就是全额');
    });

    test('正常卖出（没超卖）两个口径相同', () {
      final list = [buy(shares: 500), sell(amount: 3000, shares: 300)];
      final f = flowTotals(txns: list, start: d1, end: d2);
      expect(f.redeem, closeTo(3000, 1e-9));
      expect(f.redeemLedger, closeTo(3000, 1e-9));
    });

    test('手续费在两个口径里都是扣掉之后再折算/相加', () {
      final list = [buy(shares: 500), sell(amount: 3000, shares: 300, fee: 15)];
      final f = flowTotals(txns: list, start: d1, end: d2);
      expect(f.redeemLedger, closeTo(2985, 1e-9));
      expect(f.redeem, closeTo(2985, 1e-9));
    });

    test('账本完整时 redeemGap 为 0（这就是用户那次假警告）', () {
      // 超卖了，但现金行是全额 → 用 redeemLedger 对账必须为 0
      final st = CashFlowStatement(
        range: DateRange(d1, d2),
        beginHolding: 0,
        beginCash: 0,
        endHolding: 0,
        endCash: 0,
        deposit: 0,
        withdraw: 0,
        investAmount: 100,
        redeemAmount: 10000, // 折算后的图口径
        dividend: 0,
        cashIncome: 0,
        cashAdjust: 0,
        cashInvest: 100,
        cashRedeem: 20000, // 现金行全额
        redeemLedger: 20000, // 对账口径 = 全额
      );
      expect(st.redeemGap, closeTo(0, 1e-9));
      expect(st.ledgerIncomplete, isFalse,
          reason: '账本其实是完整的，不该报警');
    });
  });
}