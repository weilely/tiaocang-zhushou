import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/txn_form.dart';

/// 交易表单的主字段/派生字段规则
void main() {
  group('primaryFieldFor', () {
    test('买入先填金额', () {
      expect(primaryFieldFor(TxnType.buy), PrimaryField.amount);
    });

    test('卖出先填份额', () {
      expect(primaryFieldFor(TxnType.sell), PrimaryField.shares);
    });

    test('分红只有到账金额', () {
      expect(primaryFieldFor(TxnType.dividend), PrimaryField.none);
    });
  });

  group('derivedShares', () {
    test('场外基金保留 2 位小数（向下取整）', () {
      // 10000 / 1.7548 = 5698.655...
      expect(
        derivedShares(amount: 10000, price: 1.7548, kind: AssetKind.fund),
        5698.65,
      );
    });

    test('ETF / 股票取整', () {
      expect(
        derivedShares(amount: 10000, price: 4.552, kind: AssetKind.etf),
        2196,
      );
      expect(
        derivedShares(amount: 9999, price: 12.34, kind: AssetKind.stock),
        810,
      );
    });

    test('价格或金额非法时返回 null（调用方不覆盖用户输入）', () {
      expect(derivedShares(amount: 0, price: 1.75, kind: AssetKind.fund), isNull);
      expect(derivedShares(amount: 1000, price: 0, kind: AssetKind.fund), isNull);
      expect(
        derivedShares(amount: -100, price: 1.75, kind: AssetKind.fund),
        isNull,
      );
      // 金额小到算不出份额（不足 0.01 份）也不该给出 0
      expect(
        derivedShares(amount: 0.001, price: 100, kind: AssetKind.fund),
        isNull,
      );
    });
  });

  group('derivedAmount', () {
    test('份额 × 净值', () {
      expect(derivedAmount(shares: 5000, price: 4.552), closeTo(22760, 1e-9));
    });

    test('非法输入返回 null', () {
      expect(derivedAmount(shares: 0, price: 4.552), isNull);
      expect(derivedAmount(shares: 100, price: 0), isNull);
    });
  });
}
