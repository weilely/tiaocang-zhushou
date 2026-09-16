import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/home_shell.dart';
import 'package:invest_tracker/ui/settings_page.dart';
import 'package:provider/provider.dart';

/// 外壳：底部 5 项导航、改名、设置页签化
///
/// `AppState` 不调用 `init()`，所以不碰数据库：`loading` 手动置 false，
/// 其余字段用默认值，各页在空数据下都能正常渲染。
void main() {
  Future<void> pumpShell(WidgetTester tester) async {
    final st = AppState()..loading = false;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('页签定义', () {
    test('恰好 5 项，标签与顺序同设计稿', () {
      expect(kShellTabs.length, 5);
      expect(
        kShellTabs.map((t) => t.label).toList(),
        ['首页', '持仓', '调仓', '关注', '设置'],
      );
    });

    test('标签不重复（标题列表与导航项共用这一份，不会各改一半）', () {
      final labels = kShellTabs.map((t) => t.label).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('设置是最后一项', () {
      expect(kShellTabs[kSettingsTabIndex].label, '设置');
      expect(kSettingsTabIndex, kShellTabs.length - 1);
    });

    test('每个页签都有普通态与选中态图标', () {
      for (final t in kShellTabs) {
        expect(t.icon, isNotNull);
        expect(t.selectedIcon, isNotNull);
      }
    });
  });

  group('底部导航渲染', () {
    testWidgets('渲染出 5 个导航项', (tester) async {
      await pumpShell(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      for (final t in kShellTabs) {
        expect(find.text(t.label), findsWidgets, reason: '缺少页签「${t.label}」');
      }
    });

    testWidgets('旧标签「总览」「再平衡」不再出现', (tester) async {
      await pumpShell(tester);
      expect(find.text('总览'), findsNothing);
      expect(find.text('再平衡'), findsNothing);
    });

    testWidgets('标题栏不再有设置齿轮按钮（设置已是页签）', (tester) async {
      await pumpShell(tester);
      // 页签自身的图标是 Icons.settings_outlined，但它在 NavigationBar 里；
      // 这里断言 AppBar 的 actions 中没有它
      final appBarGear = find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.settings_outlined),
      );
      expect(appBarGear, findsNothing);
      // 刷新按钮仍在
      expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.refresh)),
        findsOneWidget,
      );
    });
  });

  group('设置页签化', () {
    testWidgets('点设置切到设置页，且全局只有一个 AppBar（不是双层标题栏）', (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget,
          reason: '设置页不该再自带 AppBar');
      // 设置页的内容仍在
      expect(find.textContaining('数据维护中心'), findsOneWidget);
    });

    testWidgets('设置页签下才显示内容，其它页签不显示', (tester) async {
      await pumpShell(tester);
      expect(find.textContaining('数据维护中心'), findsNothing);

      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('数据维护中心'), findsOneWidget);
    });
  });

  group('首页只有它有账户下拉与跑马灯', () {
    testWidgets('首页显示账户下拉', (tester) async {
      await pumpShell(tester);
      expect(find.text('全部账户'), findsOneWidget);
    });

    testWidgets('切到持仓页后账户下拉消失', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.text('持仓').last);
      await tester.pumpAndSettle();
      expect(find.text('全部账户'), findsNothing);
    });
  });
}
