import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/txn_edit_page.dart';
import 'package:provider/provider.dart';

/// 编辑既有记录（用户 2026-09-29 的四条字面要求）：
/// ①只显示这笔本来的操作行为（买入/卖出/分红/**再投**），别的类型禁用；
/// ②相应的数据自动填入；③「改为待确认」不出现；④没有改动时「保存」不能用。
void main() {
  final asset = Asset(id: 1, code: '025497', name: '价值100联接A', kind: AssetKind.fund);

  AppState makeState() {
    final st = AppState()..loading = false;
    st.accounts = [Account(id: 1, name: '测试账户')];
    st.accountFilter = 1;
    st.assetList = [asset];
    st.assetsById = {1: asset};
    return st;
  }

  Txn txn({
    TxnType type = TxnType.buy,
    double amount = 1000,
    double shares = 800,
    double price = 1.25,
    double fee = 0,
    String note = '',
    bool pending = false,
  }) =>
      Txn(
        id: 7,
        accountId: 1,
        assetId: 1,
        type: type,
        date: DateTime(2026, 5, 18),
        amount: amount,
        shares: shares,
        price: price,
        fee: fee,
        note: note,
        pending: pending,
      );

  Widget host(AppState st, Txn existing) => ChangeNotifierProvider<AppState>.value(
        value: st,
        child: MaterialApp(home: TxnEditPage(existing: existing)),
      );

  /// 表单很长、下面的「保存」在 ListView 里是懒构建的 —— 给个高视口，
  /// 让整页都建出来再断言（不然 finder 找不到按钮）。
  void tallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  FilledButton saveButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));

  group('编辑既有记录：只看得到这笔本来的操作行为', () {
    testWidgets('买入记录：类型段只有「买入」，且是禁用的', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn()));
      await tester.pumpAndSettle();

      expect(find.text('买入'), findsOneWidget);
      expect(find.text('卖出'), findsNothing, reason: '不相干的行为不该出现');
      expect(find.text('分红'), findsNothing);

      final seg = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>));
      expect(seg.onSelectionChanged, isNull, reason: '类型不给改');
    });

    testWidgets('红利再投记录：顶部写「再投」，不是「买入」', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(
          host(makeState(), txn(note: '红利再投 2026-05-18')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(SegmentedButton<String>, '再投'), findsOneWidget);
      expect(find.text('买入'), findsNothing);
    });

    testWidgets('备注直接写「再投」也认（对账单复刻的写法）', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn(note: '再投')));
      await tester.pumpAndSettle();

      // 备注框里也有「再投」两个字，所以只认顶部那个类型段
      expect(find.widgetWithText(SegmentedButton<String>, '再投'), findsOneWidget);
      expect(find.text('买入'), findsNothing);
    });

    testWidgets('卖出记录：只有「卖出」', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn(type: TxnType.sell)));
      await tester.pumpAndSettle();

      expect(find.text('卖出'), findsOneWidget);
      expect(find.text('买入'), findsNothing);
    });
  });

  group('编辑既有记录：数据自动填入 + 待确认 + 保存可用性', () {
    testWidgets('数据原样带出来（日期/金额/份额/净值/手续费/备注）', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(
          makeState(),
          txn(amount: 1000, shares: 800, price: 1.25, fee: 2.5, note: '定投')));
      await tester.pumpAndSettle();

      expect(find.text('2026年05月18日'), findsOneWidget, reason: '日期');
      expect(find.text('1000'), findsWidgets, reason: '金额');
      expect(find.text('800'), findsWidgets, reason: '份额');
      expect(find.text('1.25'), findsWidgets, reason: '净值');
      expect(find.text('2.5'), findsWidgets, reason: '手续费（实际）');
      expect(find.text('定投'), findsOneWidget, reason: '备注');
    });

    testWidgets('不出现「改为待确认」（待确认是记账当时的选择）', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn()));
      await tester.pumpAndSettle();

      expect(find.text('改为待确认'), findsNothing);
      expect(find.text('用查到的净值'), findsNothing);
    });

    testWidgets('本来就是待确认的记录：说明还在、开关不在', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn(pending: true)));
      await tester.pumpAndSettle();

      expect(find.textContaining('待确认'), findsWidgets);
      expect(find.text('改为待确认'), findsNothing);
    });

    testWidgets('没有改动 → 保存置灰；改一下 → 可用；改回原样 → 又置灰', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn()));
      await tester.pumpAndSettle();

      expect(saveButton(tester).onPressed, isNull, reason: '没改动不该能保存');

      final noteField = find.ancestor(
          of: find.text('备注（可选）'), matching: find.byType(TextFormField));
      await tester.enterText(noteField.first, '挪了一笔');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull, reason: '改了就该能存');

      await tester.enterText(noteField.first, '');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull, reason: '改回原样又不可存');
    });

    testWidgets('改数字字段也算改动（净值）', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(host(makeState(), txn()));
      await tester.pumpAndSettle();
      expect(saveButton(tester).onPressed, isNull);

      final navField = find.ancestor(
          of: find.text('净值'), matching: find.byType(TextFormField));
      await tester.enterText(navField.first, '1.3');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);
    });
  });
}
