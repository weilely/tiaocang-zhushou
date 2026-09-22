import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/ui/widgets/asset_value_chart.dart';

/// 「资产收益」卡片里的金额曲线
///
/// 只测纯展示层（不带 AppState / DB）：空态、单点、正常曲线、负值区间，
/// 以及**用户真机条件**（320dp 窄屏 + 字体 1.3 倍）下不许溢出。
void main() {
  ValuePoint pt(int day, double v) =>
      (date: DateTime(2026, 9, day), value: v);

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('点不够（空/单点）显示提示，不抛异常', (tester) async {
    await tester.pumpWidget(host(
        const AssetValueChart(points: [], lineColor: Colors.blue)));
    expect(find.textContaining('还没有足够的净值数据'), findsOneWidget);

    await tester.pumpWidget(host(AssetValueChart(
      points: [pt(1, 1000)],
      lineColor: Colors.blue,
    )));
    expect(find.textContaining('还没有足够的净值数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常曲线画得出来（CustomPaint 存在、不抛）', (tester) async {
    await tester.pumpWidget(host(AssetValueChart(
      points: [pt(1, 100000), pt(2, 101000), pt(3, 99000), pt(4, 120000)],
      lineColor: Colors.blue,
    )));
    expect(find.byType(CustomPaint), findsWidgets);
    // ⚠️ 尺寸必须真的撑开：`CustomPaint` 不给 size 时宽度会算成 0，
    // 屏幕上一片空白但也不会抛异常（2026-09-23 踩过）
    final size = tester.getSize(find.byKey(const Key('assetValueChart')));
    expect(size.width, greaterThan(100), reason: '宽度为 0 就等于没画');
    expect(size.height, greaterThan(50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('总收益会跨 0（负值区间）也能画，且带零轴', (tester) async {
    await tester.pumpWidget(host(AssetValueChart(
      points: [pt(1, -500), pt(2, 300), pt(3, -100), pt(4, 800)],
      lineColor: Colors.red,
      showZeroLine: true,
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('全平的一条线（刚买入没波动）不除以 0', (tester) async {
    await tester.pumpWidget(host(AssetValueChart(
      points: [pt(1, 1000), pt(2, 1000), pt(3, 1000)],
      lineColor: Colors.blue,
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 320dp + 字体 1.3 倍：不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx)
            .copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: AssetValueChart(
              points: [
                pt(1, 261234.56),
                pt(2, 268000.00),
                pt(3, 255000.10),
                pt(4, 301000.00),
              ],
              lineColor: Colors.blue,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
