import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_perf.dart';
import 'package:invest_tracker/data/index_catalog.dart';
import 'package:invest_tracker/data/index_eva.dart';
import 'package:invest_tracker/ui/index_compare_page.dart';

/// 指数对比表：逐个数取估值 / 缺数据如实说"暂无"并沉底 / 排序 / 窄屏
void main() {
  // 视口按真机来（400dp × 880dp），别用默认的 800×600
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

  IndexCatalogItem item(String code, String name,
          {double? mr, int? cons}) =>
      IndexCatalogItem(
        code: code,
        name: name,
        series: '中证系列指数',
        classify: '策略',
        assetClass: '股票',
        consNumber: cons,
        monthlyReturn: mr,
      );

  IndexValuation v({
    required String symbol,
    required String name,
    double? yeild,
    double? pe,
    double? pb,
    double? roe,
    double? pePct,
  }) =>
      IndexValuation(
        symbol: symbol,
        name: name,
        pe: pe,
        pb: pb,
        yeild: yeild,
        roe: roe,
        pePercentile: pePct,
        date: '2026-09-28',
      );

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

  /// 三个指数：中证红利（蛋卷有）、红利低波（蛋卷有）、国证价值100（蛋卷没有）
  Widget page({
    Future<IndexValuation?> Function(String, String?)? valuation,
    Future<CsiPerfPoint?> Function(String)? pe,
  }) =>
      IndexComparePage(
        items: [
          item('000922', '中证红利', mr: -1.20, cons: 100),
          item('980081', '国证价值100', mr: 3.40),
          item('H30269', '红利低波', mr: 0.80, cons: 50),
        ],
        valuationLoader: valuation ??
            (c, n) async => switch (c) {
                  '000922' => v(
                      symbol: 'SH000922',
                      name: '中证红利',
                      yeild: 0.0426,
                      pe: 8.61,
                      pb: 0.85,
                      pePct: 0.7928),
                  'H30269' => v(
                      symbol: 'CSIH30269',
                      name: '红利低波',
                      yeild: 0.0442,
                      pe: 8.48,
                      pb: 0.81,
                      pePct: 0.5032),
                  _ => null, // 蛋卷没收录
                },
        peLoader: pe ??
            (c) async => CsiPerfPoint(
                date: '20260928',
                close: 1000,
                pe: c == '980081' ? 12.5 : 9.9,
                consNumber: 100),
      );

  testWidgets('逐个取完：统计「取到估值的」个数，并说明各列来源', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('指数对比'), findsOneWidget);
    expect(find.text('对比 3 个指数'), findsOneWidget);
    expect(find.textContaining('取到估值的：2 / 3'), findsOneWidget);
    expect(find.textContaining('PE 走中证官网'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认按股息率从大到小：红利低波 4.42% 在中证红利 4.26% 之前', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('按股息率'), findsOneWidget);
    final low = tester.getTopLeft(find.text('红利低波')).dy;
    final zzh = tester.getTopLeft(find.text('中证红利')).dy;
    expect(low, lessThan(zzh));
    // 第三名（没有股息率的那条）永远沉底
    final none = tester.getTopLeft(find.text('国证价值100')).dy;
    expect(none, greaterThan(zzh));
  });

  testWidgets('蛋卷没收录的指数：股息率/PB 显示「暂无」，PE 由中证补上', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    // 国证价值100：蛋卷没有 → 股息率与 PB 都是"暂无"
    expect(find.text('暂无'), findsWidgets);
    // 但它的 PE 来自中证 index-perf（12.50）；蛋卷有的两条用蛋卷的 PE
    expect(find.text('12.50'), findsOneWidget);
    expect(find.text('8.61'), findsOneWidget); // 中证红利
    expect(find.text('8.48'), findsOneWidget); // 红利低波
  });

  testWidgets('换排序：按 PE 从小到大（缺 PE 的沉底）', (tester) async {
    await tester.pumpWidget(host(page(
      valuation: (c, n) async => c == '000922'
          ? v(symbol: 'SH000922', name: '中证红利', yeild: 0.0426, pe: 8.61)
          : null,
      pe: (c) async => CsiPerfPoint(date: '20260928', pe: switch (c) {
            '000922' => 8.6,
            'H30269' => 8.4,
            _ => 12.5,
          }),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('按股息率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按PE'));
    await tester.pumpAndSettle();
    // 图标显示的是**当前**方向：默认从大到小（↓），点它切升序
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    expect(find.text('按PE'), findsOneWidget);
    final low = tester.getTopLeft(find.text('红利低波')).dy; // 8.40
    final mid = tester.getTopLeft(find.text('中证红利')).dy; // 8.60
    final high = tester.getTopLeft(find.text('国证价值100')).dy; // 12.50
    expect(low, lessThan(mid));
    expect(mid, lessThan(high));
  });

  testWidgets('全都取不到估值：不假装有数据，页面也不崩', (tester) async {
    await tester.pumpWidget(host(page(
      valuation: (c, n) async => null,
      pe: (c) async => null,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('取到估值的：0 / 3'), findsOneWidget);
    expect(find.text('暂无'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 320dp + 字体 1.3：表格不溢出', (tester) async {
    await tester.pumpWidget(host(page(), width: 320, scale: 1.3));
    await tester.pumpAndSettle();

    expect(find.text('股息率'), findsOneWidget);
    expect(find.text('4.42%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
