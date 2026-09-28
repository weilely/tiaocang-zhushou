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

  // 用户 2026-09-28 选的做法：「待确认」模式 —— 场外基金当天净值没公布时
  // 先只记金额，等净值公布后由 `AppState.fillPendingTxns()` 按这里定的价补份额。
  group('pendingFill：待确认那笔事后补份额用哪天的价', () {
    final today = DateTime(2026, 9, 28);

    test('所选日当天就有净值 → 用当天，份额 = 金额 ÷ 净值（基金 2 位小数）', () {
      final f = pendingFill(
        date: DateTime(2026, 9, 25),
        today: today,
        priceByDay: {'2026-09-25': 1.7548},
        amount: 10000,
        traits: fund,
      )!;
      expect(f.price, closeTo(1.7548, 1e-9));
      expect(f.shares, 5698.65);
    });

    test('当天还没公布 → 顺延到之后第一个有值日（周末/节假日同理）', () {
      final f = pendingFill(
        date: DateTime(2026, 9, 25),
        today: today,
        priceByDay: {'2026-09-28': 1.8074},
        amount: 10000,
        traits: fund,
      )!;
      expect(f.price, closeTo(1.8074, 1e-9));
    });

    test('**绝不用所选日之前的价**（那等于拿买之前的价格成交）', () {
      expect(
        pendingFill(
          date: DateTime(2026, 9, 25),
          today: today,
          priceByDay: {'2026-09-24': 1.8074},
          amount: 10000,
          traits: fund,
        ),
        isNull,
      );
    });

    test('顺延日越过今天也拿不到价 → null（继续留着，下次再试）', () {
      expect(
        pendingFill(
          date: DateTime(2026, 9, 28),
          today: today,
          priceByDay: {'2026-09-28': 0},
          amount: 10000,
          traits: fund,
        ),
        isNull,
      );
    });

    test('金额算不出份额（太小 / 非法）→ null', () {
      expect(
        pendingFill(
          date: DateTime(2026, 9, 25),
          today: today,
          priceByDay: {'2026-09-25': 1.7548},
          amount: 0,
          traits: fund,
        ),
        isNull,
      );
      expect(
        pendingFill(
          date: DateTime(2026, 9, 25),
          today: today,
          priceByDay: {'2026-09-25': 1.7548},
          amount: 0.001,
          traits: fund,
        ),
        isNull,
      );
    });
  });

  group('待确认标记（DB v10 新列 pending）', () {
    test('能原样存读；老数据没有这一列 → false', () {
      final t = Txn(
        accountId: 1,
        assetId: 2,
        type: TxnType.buy,
        date: DateTime(2026, 9, 28),
        amount: 3000,
        pending: true,
      );
      expect(t.toMap()['pending'], 1);
      expect(Txn.fromMap(t.toMap()).pending, isTrue);
      final legacy = t.toMap()..remove('pending');
      expect(Txn.fromMap(legacy).pending, isFalse);
      expect(t.copyWith(pending: false).pending, isFalse);
    });
  });
}
