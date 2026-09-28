import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_board.dart';
import 'package:invest_tracker/ui/index_board_page.dart';

/// 低估榜页面：低估在前 / 股息率在列 / 分类筛选 / 自算那批标来源 / 缺数据如实说 / 窄屏
void main() {
  // 视口按真机来（400dp × 880dp）
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

  IndexBoardEntry e(String code, String name, String kind,
          {double? pePct,
          double? dividend,
          double? pe,
          double? pb,
          double? pbPct,
          double? roe,
          String symbol = 'SHx'}) =>
      IndexBoardEntry(
        code: code,
        name: name,
        kind: kind,
        symbol: symbol,
        ok: true,
        pe: pe,
        pb: pb,
        roe: roe,
        dividend: dividend,
        pePct: pePct,
        pbPct: pbPct,
        date: '09-28',
        windowStart: '20160620',
      );

  List<IndexBoardEntry> fixture() => [
        e('000015', '红利指数', '红利',
            pePct: 0.9696, dividend: 0.0400, pe: 8.94, pb: 0.86),
        e('H30094', '消费红利', '红利',
            pePct: 0.0816, dividend: 0.0462, pe: 18.94, pb: 3.39),
        e('000300', '沪深300', '宽基',
            pePct: 0.5892, dividend: 0.0274, pe: 13.13, pb: 1.39),
        e('399997', '中证白酒', '行业主题',
            pePct: 0.1092, dividend: 0.0477, pe: 19.21, pb: 3.86),
        // 中证自算那批：symbol 空 → 只有 PE 与分位
        e('930050', '中证A50', '宽基',
            pePct: 0.1116, pe: 15.33, symbol: ''),
        IndexBoardEntry(
            code: '399999', name: '没取到的', kind: '宽基', symbol: 'SHx'),
      ];

  Widget host(Widget child, {double width = 400, double scale = 1.0}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 880),
            textScaler: TextScaler.linear(scale),
          ),
          child: child,
        ),
      );

  Widget page({Future<List<IndexBoardEntry>> Function({bool force})? loader}) =>
      IndexBoardPage(
        dataAt: DateTime(2026, 9, 29),
        boardLoader: loader ?? ({bool force = false}) async => fixture(),
      );

  testWidgets('默认按 PE 分位升序：低估在前，股息率在列', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('低估榜'), findsOneWidget);
    expect(find.text('哪些指数低估'), findsOneWidget);
    expect(find.text('低估'), findsWidgets); // 标签
    expect(find.text('高估'), findsOneWidget); // 红利指数 97%
    final low = tester.getTopLeft(find.text('消费红利')).dy;
    final mid = tester.getTopLeft(find.text('沪深300')).dy;
    final high = tester.getTopLeft(find.text('红利指数')).dy;
    expect(low, lessThan(mid));
    expect(mid, lessThan(high));
    expect(find.textContaining('股息率 4.62%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部结论：低估几个 + 有数据几个（不含"没取到"的）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    // 低估：消费红利 8.2 / 中证白酒 10.9 / 中证A50 11.2 = 3；有数据 5（"没取到的"不算）
    expect(find.textContaining('3'), findsWidgets);
    expect(find.textContaining('个指数处在低估区'), findsOneWidget);
    expect(find.textContaining('共 5 个有数据'), findsOneWidget);
    expect(find.textContaining('另有 1 个这次没取到'), findsOneWidget);
  });

  testWidgets('分类筛选：只看红利 / 只看宽基', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '红利'));
    await tester.pumpAndSettle();
    expect(find.text('红利（估值排名）'), findsOneWidget);
    expect(find.text('消费红利'), findsOneWidget);
    expect(find.text('红利指数'), findsOneWidget);
    expect(find.text('沪深300'), findsNothing);
    expect(find.text('中证白酒'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '宽基'));
    await tester.pumpAndSettle();
    expect(find.text('沪深300'), findsOneWidget);
    expect(find.text('中证A50'), findsOneWidget);
    expect(find.text('消费红利'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pumpAndSettle();
    expect(find.text('消费红利'), findsOneWidget);
    expect(find.text('中证白酒'), findsOneWidget);
  });

  testWidgets('中证自算那批：行内标「分位·中证自算」，弹层说明是自己算的', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.textContaining('分位·中证自算'), findsOneWidget);
    await tester.tap(find.text('中证A50'));
    await tester.pumpAndSettle();
    expect(find.textContaining('分位是自己算的'), findsOneWidget);
    expect(find.textContaining('没有股息率/PB/ROE'), findsOneWidget);
    expect(find.text('--'), findsWidgets); // 股息率/PB/ROE 都是 --
  });

  testWidgets('蛋卷那批的弹层写明数据源与分位窗口', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('消费红利'));
    await tester.pumpAndSettle();
    expect(find.textContaining('蛋卷指数估值'), findsOneWidget);
    expect(find.textContaining('分位窗口起点 20160620'), findsOneWidget);
    expect(find.text('4.62%'), findsOneWidget);
    expect(find.text('8.16%'), findsOneWidget);
  });

  testWidgets('缺数据的那条如实说「这次没取到」，不显示 0，并沉底', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    expect(find.text('这次没取到'), findsOneWidget);
    expect(tester.getTopLeft(find.text('没取到的')).dy,
        greaterThan(tester.getTopLeft(find.text('红利指数')).dy));
  });

  testWidgets('换排序：按股息率（高→低）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('按PE 分位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按股息率'));
    await tester.pumpAndSettle();

    expect(find.text('按股息率'), findsOneWidget);
    final a = tester.getTopLeft(find.text('中证白酒')).dy; // 4.77%
    final b = tester.getTopLeft(find.text('消费红利')).dy; // 4.62%
    final c = tester.getTopLeft(find.text('沪深300')).dy; // 2.74%
    expect(a, lessThan(b));
    expect(b, lessThan(c));
  });

  testWidgets('界面文案里不许出现 markdown 星号（Flutter 不渲染）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(texts.contains('**'), isFalse);
  });

  testWidgets('页脚不与"没插值的表达式"混在一起（list.length 那种坑）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(texts.contains('成员 ${kIndexBoardSeeds.length} 个'), isTrue);
    // 一旦漏了花括号，整张成员表会被 toString 打进文案里
    expect(texts.contains('symbol:'), isFalse);
    expect(texts.contains('.length'), isFalse);
  });

  testWidgets('窄屏 320dp + 字体 1.3：榜单与筛选都不溢出', (tester) async {
    await tester.pumpWidget(host(page(), width: 320, scale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('消费红利'), findsOneWidget);
    expect(find.textContaining('股息率 4.62%'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '红利'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('取不到数据 → 空态如实说（不假装榜是空的）', (tester) async {
    await tester.pumpWidget(host(page(
      loader: ({bool force = false}) async => const [],
    )));
    await tester.pumpAndSettle();
    expect(find.text('还没拿到数据'), findsOneWidget);
    expect(find.textContaining('点右上角刷新'), findsOneWidget);
  });
}
