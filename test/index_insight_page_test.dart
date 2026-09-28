import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/db.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/index_insight_page.dart';
import 'package:provider/provider.dart';

/// 指数看板：一个入口三个标签（低估榜 / 市场估值 / 查指数）
///
/// 这里用**真的 AppState**（只验结构与切换）。注意：**不能用 `pumpAndSettle`** ——
/// AppState 带后台定时器、页面里还有加载进度条，帧永远不会停；改成按帧推。
/// 测试环境下 http 被 Flutter 的测试 binding 拦成 400、path_provider 抛
/// MissingPlugin，两处都被代码 catch，所以各标签页显示自己的空态/缓存态，不联网。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.platformDispatcher.implicitView!.physicalSize =
        const Size(1200, 2640);
    binding.platformDispatcher.implicitView!.devicePixelRatio = 3.0;
  });
  tearDown(() {
    binding.platformDispatcher.implicitView!.resetPhysicalSize();
    binding.platformDispatcher.implicitView!.resetDevicePixelRatio();
  });

  /// 推几帧（别用 pumpAndSettle：后台定时器 + 进度条会让它永远等下去）
  Future<void> pumpABit(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Widget host({double width = 400, double scale = 1.0, AppState? st}) =>
      ChangeNotifierProvider<AppState>(
        create: (_) => st ?? AppState(),
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 880),
              textScaler: TextScaler.linear(scale),
            ),
            child: const IndexInsightPage(),
          ),
        ),
      );

  testWidgets('三个标签都在，默认开在「低估榜」', (tester) async {
    await tester.pumpWidget(host());
    await pumpABit(tester);

    expect(find.text('指数看板'), findsOneWidget);
    expect(find.widgetWithText(Tab, '低估榜'), findsOneWidget);
    expect(find.widgetWithText(Tab, '市场估值'), findsOneWidget);
    expect(find.widgetWithText(Tab, '查指数'), findsOneWidget);
    expect(find.text('哪些指数低估'), findsOneWidget); // 默认标签 = 低估榜
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到「市场估值」→ 出股债利差那一套', (tester) async {
    await tester.pumpWidget(host());
    await pumpABit(tester);

    await tester.tap(find.widgetWithText(Tab, '市场估值'));
    await pumpABit(tester);

    expect(find.text('股债利差'), findsOneWidget);
    // 没有宏观数据时如实说（不显示 0%）
    expect(find.textContaining('还没取到宏观估值数据'), findsOneWidget);
    // 文案里不许出现 toString 痕迹（点号表达式漏花括号的统一痕迹）
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(texts.contains("Instance of '"), isFalse);
    expect(texts.contains('**'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('市场估值（有数据时）：利差 + 沪深300 两条线、图例、可缩放说明', (tester) async {
    // 直接往 AppState 的公开字段灌数据（不碰 DB、不联网）
    final st = AppState()
      ..macroHistory = [
        for (var i = 0; i < 40; i++)
          MacroRow(
            date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
            hs300Pe: 12 + i * 0.05,
            cn10y: 1.7,
            erp: 100 / (12 + i * 0.05) - 1.7,
          ),
      ]
      ..indexNavs['sh000300'] = [
        for (var i = 0; i < 40; i++)
          NavPoint(
            code: 'sh000300',
            date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
            nav: 4000 + i * 12,
          ),
      ];

    await tester.pumpWidget(host(st: st));
    await pumpABit(tester);
    await tester.tap(find.widgetWithText(Tab, '市场估值'));
    await pumpABit(tester);

    expect(find.text('历史曲线'), findsOneWidget);
    // 卡头是缩放按钮（手机上双指不好按，按钮才是主要入口）
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);
    // 两条线的图例都在（右边那条是沪深300 区间收益，看右轴）
    expect(find.textContaining('股债利差（左轴'), findsOneWidget);
    expect(find.text('沪深300 区间收益（右轴 %）'), findsOneWidget);
    // 窗口说明 + 手势提示
    expect(find.textContaining('点卡头 − / + 缩放、复位回全览'), findsOneWidget);
    expect(find.textContaining('区间收益以当前可见窗口的第一天为基准'), findsOneWidget);
    expect(find.textContaining("Instance of '"), findsNothing);

    // 复位按钮：全览时禁用 → 放大后可用 → 复位后回到禁用（等于验证了缩放真的接上了）
    IconButton resetBtn() => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.restart_alt));
    expect(resetBtn().onPressed, isNull, reason: '一开始就是全览，复位该是禁用的');
    await tester.tap(find.byIcon(Icons.add));
    await pumpABit(tester);
    expect(resetBtn().onPressed, isNotNull, reason: '放大后复位该可用');
    await tester.tap(find.byIcon(Icons.restart_alt));
    await pumpABit(tester);
    expect(resetBtn().onPressed, isNull, reason: '复位后应回到全览');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到「查指数」→ 出搜索那套（原来那页的功能没丢）', (tester) async {
    await tester.pumpWidget(host());
    await pumpABit(tester);

    await tester.tap(find.widgetWithText(Tab, '查指数'));
    await pumpABit(tester);

    expect(find.text('搜索指数'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // 搜索框还在
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 320dp + 字体 1.3：标签栏与三个标签页都不溢出', (tester) async {    await tester.pumpWidget(host(width: 320, scale: 1.3));
    await pumpABit(tester);
    expect(find.text('哪些指数低估'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '市场估值'));
    await pumpABit(tester);
    await tester.tap(find.widgetWithText(Tab, '查指数'));
    await pumpABit(tester);
    expect(tester.takeException(), isNull);
  });
}
