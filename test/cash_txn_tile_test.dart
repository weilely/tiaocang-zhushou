import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/ui/widgets/cash_txn_tile.dart';

/// 现金流水行：**交易联动生成的那条不能在现金页删除**
void main() {
  CashTxn manual({
    String type = CashType.deposit,
    double amount = 10000,
    String note = '',
  }) =>
      CashTxn(
        id: 1,
        accountId: 1,
        type: type,
        amount: amount,
        date: DateTime(2026, 9, 11),
        note: note,
      );

  /// 由交易联动生成：带 srcTxnId
  CashTxn linked({
    String type = CashType.invest,
    double amount = -15700,
    String note = '来自买入',
  }) =>
      CashTxn(
        id: 2,
        accountId: 1,
        type: type,
        amount: amount,
        date: DateTime(2026, 9, 11),
        note: note,
        srcTxnId: 42,
      );

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('展示', () {
    testWidgets('手工流水：显示类型与金额，没有「自动」标', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: manual(),
        onDelete: () {},
      )));
      expect(find.text('充值'), findsOneWidget);
      expect(find.text('+10,000.00'), findsOneWidget);
      expect(find.text('自动'), findsNothing);
      expect(find.textContaining('随交易自动记'), findsNothing);
    });

    testWidgets('联动流水：带「自动」标，并说明去哪儿删', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(),
        onDelete: null,
      )));
      expect(find.text('买入扣款'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      expect(find.textContaining('请到交易记录里删'), findsOneWidget);
      expect(find.text('-15,700.00'), findsOneWidget);
    });

    testWidgets('账户名按传入决定是否显示', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: manual(),
        accountName: '默认账户',
        onDelete: () {},
      )));
      expect(find.textContaining('默认账户'), findsOneWidget);
    });
  });

  group('可删性', () {
    testWidgets('手工流水：有 Dismissible，左滑触发删除回调', (tester) async {
      var deleted = 0;
      await tester.pumpWidget(host(CashTxnTile(
        txn: manual(),
        onDelete: () => deleted++,
      )));

      expect(find.byType(Dismissible), findsOneWidget);
      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(deleted, 1);
    });

    testWidgets('联动流水：连 Dismissible 都不存在（结构上就删不了）', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(),
        onDelete: null,
      )));

      expect(find.byType(Dismissible), findsNothing,
          reason: '不该构造出可滑动删除的容器');
    });

    testWidgets('联动流水：即使误传了删除回调也不可删', (tester) async {
      var deleted = 0;
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(),
        // 页面若改错传了回调，这里也必须兜住
        onDelete: () => deleted++,
      )));

      expect(find.byType(Dismissible), findsNothing);
      await tester.drag(find.byType(CashTxnTile), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(deleted, 0, reason: '联动流水任何时候都不该被现金页删掉');
      expect(find.byType(CashTxnTile), findsOneWidget, reason: '行还在');
    });

    test('deletable 的判据：必须同时「非联动」且「给了回调」', () {
      expect(
        CashTxnTile(txn: manual(), onDelete: () {}).deletable,
        isTrue,
      );
      expect(CashTxnTile(txn: manual()).deletable, isFalse);
      expect(CashTxnTile(txn: linked(), onDelete: () {}).deletable, isFalse);
      expect(CashTxnTile(txn: linked()).deletable, isFalse);
    });

    test('isAuto 只看 srcTxnId', () {
      expect(CashTxnTile(txn: linked()).isAuto, isTrue);
      expect(CashTxnTile(txn: manual()).isAuto, isFalse);
      // 手工记的「分红」不是联动流水（联动的一定带 srcTxnId）
      expect(
        CashTxnTile(txn: manual(type: CashType.dividend, amount: 88)).isAuto,
        isFalse,
      );
    });
  });
}
