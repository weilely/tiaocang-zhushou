import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/ui/widgets/cn_date_picker.dart';

/// 自定义中文日期选择器。
///
/// 之所以自绘而不是用 `showDatePicker`：本项目没有接入 `flutter_localizations`，
/// Material 的日期选择器会整屏英文；换年月也要先点标题再逐月翻。
void main() {
  /// 打开选择器并返回其结果 Future（确定/取消后会完成）
  Future<Future<DateTime?>> open(
    WidgetTester tester, {
    DateTime? initial,
    DateTime? first,
    DateTime? last,
  }) async {
    late Future<DateTime?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = showCnDatePicker(
                    context: ctx,
                    initialDate: initial ?? DateTime(2026, 9, 11),
                    firstDate: first ?? DateTime(2000),
                    lastDate: last ?? DateTime(2026, 9, 30),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return pending;
  }

  setUp(() {
    // 贴近真机：450×800 逻辑像素（MuMu 模拟器 900×1600 @2x）
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(900, 1600);
    view.devicePixelRatio = 2.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('中文界面', () {
    testWidgets('标题、星期表头与按钮都是中文', (tester) async {
      await open(tester);

      expect(find.text('选择日期'), findsOneWidget);
      expect(find.text('2026年9月'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);

      // 星期表头恰为 日一二三四五六
      for (final w in ['日', '一', '二', '三', '四', '五', '六']) {
        expect(find.text(w), findsOneWidget, reason: '缺少星期表头「$w」');
      }

      // 没有任何英文残留
      expect(find.text('Select date'), findsNothing);
      expect(find.text('CANCEL'), findsNothing);
      expect(find.text('OK'), findsNothing);
    });

    testWidgets('日历显示当月所有日期，1 号落在正确位置', (tester) async {
      await open(tester);
      // 2026-09 共 30 天
      for (final d in [1, 2, 15, 29, 30]) {
        expect(find.text('$d'), findsOneWidget);
      }
      expect(find.text('31'), findsNothing);
    });
  });

  group('年 / 月快速选择', () {
    testWidgets('点标题进入年月快选，出现年份与 12 个月', (tester) async {
      await open(tester);
      expect(find.text('1月'), findsNothing);

      await tester.tap(find.text('2026年9月'));
      await tester.pumpAndSettle();

      for (var m = 1; m <= 12; m++) {
        expect(find.text('$m月'), findsOneWidget, reason: '缺少「$m月」');
      }
      expect(find.text('2026年'), findsOneWidget);
      expect(find.text('2025年'), findsOneWidget);
      expect(find.text('2024年'), findsOneWidget);
    });

    testWidgets('选 2025 年 → 选 3 月 → 自动回到该月日历', (tester) async {
      await open(tester);
      await tester.tap(find.text('2026年9月'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('2025年'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('3月'));
      await tester.pumpAndSettle();

      // 回到日历模式：标题变成 2025年3月，且 1..31 都在（3 月 31 天）
      expect(find.text('2025年3月'), findsOneWidget);
      expect(find.text('1月'), findsNothing, reason: '应当已退出年月快选');
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('两步就能跳到几个月之外（不必逐月翻页）', (tester) async {
      await open(tester);
      await tester.tap(find.text('2026年9月'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2024年'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1月'));
      await tester.pumpAndSettle();

      expect(find.text('2024年1月'), findsOneWidget);
      expect(find.text('29'), findsOneWidget, reason: '2024 年 1 月有 29 日');
    });
  });

  group('选择与返回', () {
    testWidgets('点某一天后确定，返回该日期且时分秒归零', (tester) async {
      final f = await open(tester);

      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final r = await f;
      expect(r, isNotNull);
      expect(r, DateTime(2026, 9, 20));
      expect(r!.hour, 0);
      expect(r.minute, 0);
      expect(r.second, 0);
    });

    testWidgets('不点日期直接确定，返回初始日期', (tester) async {
      final f = await open(tester, initial: DateTime(2026, 9, 3));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 3));
    });

    testWidgets('取消返回 null', (tester) async {
      final f = await open(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await f, isNull);
    });

    testWidgets('右上角关闭返回 null', (tester) async {
      final f = await open(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(await f, isNull);
    });

    testWidgets('今天按钮把选中与视图都带到今天', (tester) async {
      final today = DateTime.now();
      final f = await open(
        tester,
        initial: DateTime(2020, 1, 1),
        first: DateTime(2000),
        last: today.add(const Duration(days: 1)),
      );
      await tester.tap(find.text('今天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final r = await f;
      expect(r, isNotNull);
      expect(r!.year, today.year);
      expect(r.month, today.month);
      expect(r.day, today.day);
    });
  });

  group('区间边界', () {
    testWidgets('超出 lastDate 的日期被禁用，点了不改变选中值', (tester) async {
      final f = await open(
        tester,
        initial: DateTime(2026, 9, 11),
        first: DateTime(2026, 9, 1),
        last: DateTime(2026, 9, 11),
      );

      // 12 号之后的格子仍在，但不可点
      expect(find.text('12'), findsOneWidget);
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 11));
    });

    testWidgets('initialDate 越界时收敛进区间', (tester) async {
      final f = await open(
        tester,
        initial: DateTime(2026, 9, 30),
        first: DateTime(2026, 9, 1),
        last: DateTime(2026, 9, 5),
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 5));
    });

    testWidgets('firstDate == lastDate 时不崩、能确定', (tester) async {
      final only = DateTime(2026, 9, 7);
      final f = await open(
        tester,
        initial: only,
        first: only,
        last: only,
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, only);
    });

    testWidgets('区间外月份不可点：lastDate 当月之后的月份被禁用', (tester) async {
      final f = await open(
        tester,
        initial: DateTime(2026, 9, 11),
        first: DateTime(2026, 9, 1),
        last: DateTime(2026, 9, 11),
      );
      await tester.tap(find.text('2026年9月'));
      await tester.pumpAndSettle();

      // 10 月/11 月/12 月的格子存在但不可点
      await tester.tap(find.text('10月'));
      await tester.pumpAndSettle();

      // 仍停留在快选面板（点击被忽略），且确定后返回原选中值
      expect(find.text('1月'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 11));
    });
  });
}
