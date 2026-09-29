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

  // 用户 2026-09-29：「所有日期控件把选择年和月改为箭头选择。外层箭头控制年，
  // 内侧箭头（比外侧小一点）控制月」—— 原来那种「点标题弹年月快选面板」已去掉。
  group('年月导航（外层箭头控年、内侧箭头控月）', () {
    testWidgets('内侧箭头换月、外层箭头换年，标题跟着走', (tester) async {
      // 区间放宽到 2027 年底：不然「下个月」会撞上 lastDate 被置灰
      await open(tester,
          initial: DateTime(2026, 9, 11),
          first: DateTime(2000),
          last: DateTime(2027, 12, 31));
      expect(find.text('2026年9月'), findsOneWidget);

      // 内侧：上个月 → 8 月
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text('2026年8月'), findsOneWidget);

      // 内侧：下个月 ×2 → 10 月
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byIcon(Icons.chevron_right));
        await tester.pumpAndSettle();
      }
      expect(find.text('2026年10月'), findsOneWidget);

      // 外层：上一年 → 2025 年 10 月（月份不动）
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
      await tester.pumpAndSettle();
      expect(find.text('2025年10月'), findsOneWidget);

      // 外层：下一年 → 回到 2026 年 10 月
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();
      expect(find.text('2026年10月'), findsOneWidget);

      // 一个「年月快选面板」的格子都不该再出现
      expect(find.text('1月'), findsNothing);
    });

    testWidgets('翻年月只改视图，不偷偷改已选日期', (tester) async {
      final f = await open(tester);
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 11), reason: '翻年月不该改选中的日期');
    });

    testWidgets('换到别的月后日历跟着换（3 月有 31 天）', (tester) async {
      await open(tester);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pumpAndSettle();
      }
      expect(find.text('2026年3月'), findsOneWidget);
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('越界的箭头置灰：区间外的年 / 月挪不过去', (tester) async {
      await open(
        tester,
        initial: DateTime(2026, 9, 11),
        first: DateTime(2026, 1, 1),
        last: DateTime(2026, 9, 11),
      );

      IconButton byIcon(IconData i) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, i));

      // 9 月已经是区间上限 → 下个月 / 下一年都点不动
      expect(byIcon(Icons.chevron_right).onPressed, isNull);
      expect(byIcon(Icons.keyboard_double_arrow_right).onPressed, isNull);
      // 往前：换月还能走（2026-08 在区间里），换年不行（2025-09 在区间外）
      expect(byIcon(Icons.chevron_left).onPressed, isNotNull);
      expect(byIcon(Icons.keyboard_double_arrow_left).onPressed, isNull);
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

    testWidgets('区间外的月份挪不过去（换月箭头置灰）', (tester) async {
      final f = await open(
        tester,
        initial: DateTime(2026, 9, 11),
        first: DateTime(2026, 9, 1),
        last: DateTime(2026, 9, 11),
      );
      // 区间只有 9 月这一个月：往前、往后都点不动
      expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.chevron_left))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.chevron_right))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await f, DateTime(2026, 9, 11));
    });
  });
}
