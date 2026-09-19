import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/dividend.dart';
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

    ({double invest, double redeem, double dividend}) totals(List<Txn> list) =>
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
}
