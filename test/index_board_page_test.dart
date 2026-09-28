import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_board.dart';
import 'package:invest_tracker/data/index_eva.dart';
import 'package:invest_tracker/ui/index_board_page.dart';

/// 低估榜页面：默认低估在前 / 股息率在列 / 点开看细节 / 缺数据如实说 / 窄屏
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

  IndexBoardEntry e(String code, String name,
          {double? pePct,
          double? yeild,
          double? pe,
          double? pb,
          double? roe,
          double? pbPct}) =>
      IndexBoardEntry(
        symbol: 'SH$code',
        code: code,
        name: name,
        v: IndexValuation(
          symbol: 'SH$code',
          name: name,
          pe: pe,
          pb: pb,
          yeild: yeild,
          roe: roe,
          pePercentile: pePct,
          pbPercentile: pbPct,
          windowStart: DateTime(2016, 6, 20),
          date: '09-28',
        ),
      );

  List<IndexBoardEntry> fixture() => [
        e('000015', '红利指数', pePct: 0.9696, yeild: 0.0400, pe: 8.94, pb: 0.86),
        e('H30094', '消费红利', pePct: 0.0816, yeild: 0.0462, pe: 18.94, pb: 3.39),
        e('000300', '沪深300', pePct: 0.5892, yeild: 0.0274, pe: 13.13, pb: 1.39),
        IndexBoardEntry(symbol: 'SH399999', code: '399999', name: '没取到的'),
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
        boardLoader: loader ??
            ({bool force = false}) async => fixture(),
      );

  testWidgets('默认按 PE 分位升序：低估在前，股息率在列', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('低估榜'), findsOneWidget);
    expect(find.text('哪些指数低估'), findsOneWidget);
    // 三档标签
    expect(find.text('低估'), findsOneWidget);
    expect(find.text('高估'), findsOneWidget);
    // 排序位置：消费红利(8.2%) < 沪深300(58.9%) < 红利指数(97.0%)
    final low = tester.getTopLeft(find.text('消费红利')).dy;
    final mid = tester.getTopLeft(find.text('沪深300')).dy;
    final high = tester.getTopLeft(find.text('红利指数')).dy;
    expect(low, lessThan(mid));
    expect(mid, lessThan(high));
    // 行里带股息率
    expect(find.textContaining('股息率 4.62%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部给出"几个低估"的结论', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    expect(find.textContaining('个指数处在低估区'), findsOneWidget);
  });

  testWidgets('缺数据的那条如实说「这次没取到」，不显示 0', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    expect(find.text('这次没取到'), findsOneWidget);
    expect(tester.getTopLeft(find.text('没取到的')).dy,
        greaterThan(tester.getTopLeft(find.text('红利指数')).dy)); // 沉底
  });

  testWidgets('点一行 → 弹出细节（股息率 / PE 分位 / ROE / 分位窗口）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('消费红利'));
    await tester.pumpAndSettle();

    expect(find.textContaining('股息率（指数成分股口径）'), findsOneWidget);
    expect(find.text('4.62%'), findsOneWidget);
    expect(find.text('PE 历史分位'), findsOneWidget);
    expect(find.text('8.16%'), findsOneWidget);
    expect(find.textContaining('分位窗口起点 2016-06-20'), findsOneWidget);
  });

  testWidgets('换排序：按股息率（高→低）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('按PE 分位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按股息率'));
    await tester.pumpAndSettle();

    expect(find.text('按股息率'), findsOneWidget);
    final a = tester.getTopLeft(find.text('消费红利')).dy; // 4.62%
    final b = tester.getTopLeft(find.text('红利指数')).dy; // 4.00%
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

  testWidgets('窄屏 320dp + 字体 1.3：榜单不溢出', (tester) async {
    await tester.pumpWidget(host(page(), width: 320, scale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('消费红利'), findsOneWidget);
    expect(find.textContaining('股息率 4.62%'), findsOneWidget);
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
