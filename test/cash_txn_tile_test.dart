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

    testWidgets('联动流水：带「自动」标（明细已精简，不再提示去哪儿删）', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(),
        onDelete: null,
      )));
      expect(find.text('买入扣款'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      expect(find.textContaining('随交易自动记'), findsNothing);
      expect(find.textContaining('请到交易记录里删'), findsNothing);
      expect(find.text('-15,700.00'), findsOneWidget);
    });

    testWidgets('定投联动流水：标题写「定投」，不再写「买入扣款」', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(note: '价值100 · 定投'),
        onDelete: null,
      )));
      expect(find.text('定投'), findsOneWidget);
      expect(find.text('买入扣款'), findsNothing);
      // 动作词已在标题里，副标题只留标的简称（不重复出现「定投」）
      expect(find.textContaining('价值100'), findsOneWidget);
      expect(find.textContaining('· 定投'), findsNothing);
    });

    testWidgets('联动买入：标题已写「买入扣款」，副标题不再重复动作词', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(note: '价值100 · 买入'),
        onDelete: null,
      )));
      expect(find.text('买入扣款'), findsOneWidget);
      expect(find.textContaining('价值100'), findsOneWidget);
      // 断言的是「价值100 · 买入」这个**连续子串**：
      // 早先写 find.textContaining('买入扣款 · 买入') 是测不出问题的
      // （标题与备注拼不成那个串），备注里的动作词滤没滤掉，这条才卡得住。
      expect(find.textContaining('价值100 · 买入'), findsNothing,
          reason: '动作词「买入」由标题表达，备注里要滤掉');
    });

    testWidgets('联动卖出 / 分红：备注里也只留简称', (tester) async {
      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(type: CashType.redeem, amount: 800, note: '价值100 · 卖出'),
        onDelete: null,
      )));
      expect(find.text('卖出入账'), findsOneWidget);
      expect(find.textContaining('价值100 · 卖出'), findsNothing);

      await tester.pumpWidget(host(CashTxnTile(
        txn: linked(type: CashType.dividend, amount: 88, note: '价值100 · 分红'),
        onDelete: null,
      )));
      expect(find.text('分红入账'), findsOneWidget);
      expect(find.textContaining('价值100 · 分红'), findsNothing);
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
    testWidgets('手工流水：左滑先弹确认框，点「删除」才真的删', (tester) async {
      var deleted = 0;
      await tester.pumpWidget(host(CashTxnTile(
        txn: manual(),
        onDelete: () => deleted++,
      )));

      expect(find.byType(Dismissible), findsOneWidget);
      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pumpAndSettle();

      // 先出确认框，此时还没删
      expect(find.text('删除这条现金流水？'), findsOneWidget);
      expect(deleted, 0, reason: '确认之前不应删除');

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
    });

    testWidgets('手工流水：确认框点「取消」不删除，行弹回原位', (tester) async {
      var deleted = 0;
      await tester.pumpWidget(host(CashTxnTile(
        txn: manual(),
        onDelete: () => deleted++,
      )));

      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('删除这条现金流水？'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(deleted, 0);
      expect(find.byType(CashTxnTile), findsOneWidget, reason: '行还在');
      expect(find.text('删除这条现金流水？'), findsNothing);
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
