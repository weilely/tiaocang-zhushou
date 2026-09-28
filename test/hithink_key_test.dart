import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/settings_page.dart';
import 'package:provider/provider.dart';

/// 同花顺 Key 的输入方式（用户 2026-09-28）：
/// 「用**弹框**输入并保持，**不要直接显示**，容易误填，**一同备份**」
///
/// 所以设置页里**不再常驻一个输入框**（那是误填的来源），只显示「已设置 / 未设置」，
/// 改 Key 走弹框、输入内容打码。
void main() {
  Future<void> pump(WidgetTester tester, AppState st) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('卡片只显示「已设置（N 位）」不显示内容；改 Key 走打码弹框', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final st = AppState()..loading = false;
    const key = 'sk-fuyao-abcdefghijklmn';
    st.hithinkApiKey = key;
    await pump(tester, st);

    // 卡片默认收起
    await tester.tap(find.text('同花顺数据源（备用）'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已设置（共'), findsOneWidget);
    expect(find.textContaining('sk-fuyao'), findsNothing,
        reason: '不许把 Key 明文显示出来');
    expect(find.text('修改'), findsOneWidget);

    // 弹框：输入框打码，取消不改动
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('同花顺 API Key'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.obscureText, isTrue, reason: '弹框里也要打码');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(st.hithinkApiKey, key, reason: '取消不该动 Key');
  });

  testWidgets('未设置时显示「未设置」+「设置」按钮', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final st = AppState()..loading = false;
    st.hithinkApiKey = '';
    await pump(tester, st);

    await tester.tap(find.text('同花顺数据源（备用）'));
    await tester.pumpAndSettle();
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 页面里不该再有一个常驻的 Key 输入框（只有「账户名称」这类别的框）
    expect(find.byType(TextField), findsNothing,
        reason: '常驻输入框是误填的来源，已改成弹框');
  });
}
