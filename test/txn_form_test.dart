import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/asset_traits.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/txn_form.dart';

/// 交易表单的主字段/派生字段规则
///
/// 2026-09-24 起买入方向**按标的类型分叉**：场外基金是按金额申购（先填金额），
/// 场内（ETF/股票）是按股数下单（先填股数）。规则只在 `asset_traits.dart` 里。
void main() {
  final fund = AssetKind.fund.traits;
  final etf = AssetKind.etf.traits;
  final stock = AssetKind.stock.traits;

  group('primaryFieldFor', () {
    test('场外基金买入先填金额', () {
      expect(primaryFieldFor(TxnType.buy, fund), PrimaryField.amount);
    });

    test('场内（ETF/股票）买入先填股数', () {
      expect(primaryFieldFor(TxnType.buy, etf), PrimaryField.shares);
      expect(primaryFieldFor(TxnType.buy, stock), PrimaryField.shares);
    });

    test('卖出一律先填份额', () {
      expect(primaryFieldFor(TxnType.sell, fund), PrimaryField.shares);
      expect(primaryFieldFor(TxnType.sell, stock), PrimaryField.shares);
    });

    test('分红只有到账金额', () {
      expect(primaryFieldFor(TxnType.dividend, fund), PrimaryField.none);
    });
  });

  group('derivedShares', () {
    test('场外基金保留 2 位小数（向下取整）', () {
      // 10000 / 1.7548 = 5698.655...
      expect(
        derivedShares(amount: 10000, price: 1.7548, traits: fund),
        5698.65,
      );
    });

    test('场内按一手（100 股/份）向下取整', () {
      // 10000 / 4.552 = 2196.8 → 2100（21 手）
      expect(derivedShares(amount: 10000, price: 4.552, traits: etf), 2100);
      // 9999 / 12.34 = 810.3 → 800（8 手）
      expect(derivedShares(amount: 9999, price: 12.34, traits: stock), 800);
    });

    test('买不起一手就返回 null，不给一个下不了单的碎股数', () {
      // 100 / 12.34 = 8.1 股 < 1 手
      expect(derivedShares(amount: 100, price: 12.34, traits: stock), isNull);
      // 整好一手可以用
      expect(derivedShares(amount: 1234, price: 12.34, traits: stock), 100);
    });

    test('价格或金额非法时返回 null（调用方不覆盖用户输入）', () {
      expect(derivedShares(amount: 0, price: 1.75, traits: fund), isNull);
      expect(derivedShares(amount: 1000, price: 0, traits: fund), isNull);
      expect(derivedShares(amount: -100, price: 1.75, traits: fund), isNull);
      // 金额小到算不出份额（不足 0.01 份）也不该给出 0
      expect(derivedShares(amount: 0.001, price: 100, traits: fund), isNull);
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
