import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/db.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/ui/widgets/macro_card.dart';

/// 曲线窗口（缩放/平移）的纯逻辑 + 曲线的渲染冒烟
void main() {
  group('ChartWindow：缩放 / 平移 / 取下标', () {
    test('全览 → slice 覆盖所有点（闭区间）', () {
      expect(ChartWindow.full.isFull, isTrue);
      expect(ChartWindow.full.slice(10), (0, 9));
      expect(ChartWindow.full.slice(2), (0, 1));
    });

    test('放大：锚点位置保持在原来的比例上', () {
      const w = ChartWindow(0, 1);
      final z = w.zoomed(2, 0.5); // 以正中为锚放大一倍
      expect(z.span, closeTo(0.5, 1e-9));
      expect(z.start, closeTo(0.25, 1e-9));
      expect(z.end, closeTo(0.75, 1e-9));
      // 锚点 0.5 在新窗口里还是 0.5
      expect((0.5 - z.start) / z.span, closeTo(0.5, 1e-9));
    });

    test('放大到最小可见比例就停住（再小只剩一两个点）', () {
      final z = ChartWindow.full.zoomed(1000, 0.5);
      expect(z.span, closeTo(ChartWindow.minSpan, 1e-9));
      expect(z.start, lessThan(z.end));
      expect(z.start, greaterThanOrEqualTo(0));
      expect(z.end, lessThanOrEqualTo(1));
    });

    test('缩到底不会超过全览，也不会把 start/end 弄反或越界', () {
      final z = ChartWindow(0.2, 0.4).zoomed(0.01, 0.3);
      expect(z.span, closeTo(1.0, 1e-9));
      expect(z.start, 0);
      expect(z.end, 1);
    });

    test('平移撞到两端会被夹住（不会露出范围外的空白）', () {
      const w = ChartWindow(0.2, 0.5);
      final right = w.panned(10); // 往右推到底
      expect(right.end, closeTo(1.0, 1e-9));
      expect(right.span, closeTo(0.3, 1e-9)); // 宽度不变
      final left = w.panned(-10);
      expect(left.start, closeTo(0.0, 1e-9));
      expect(left.span, closeTo(0.3, 1e-9));
    });

    test('slice 至少给两个点，且不越界', () {
      const w = ChartWindow(0.999, 1.0); // 极窄
      final (i0, i1) = w.slice(100);
      expect(i0, lessThan(i1));
      expect(i0, greaterThanOrEqualTo(0));
      expect(i1, lessThanOrEqualTo(99));
    });

    test('非法输入不炸（NaN / 0 / 负）', () {
      expect(ChartWindow.full.zoomed(double.nan, 0.5).isFull, isTrue);
      expect(ChartWindow.full.zoomed(0, 0.5).isFull, isTrue);
      expect(ChartWindow.full.zoomed(-3, 0.5).isFull, isTrue);
    });
  });

  group('ErpChartController：缩放按钮共用的窗口状态', () {
    test('放大 → span 变小；缩小 → 变大；复位 → 回全览', () {
      final c = ErpChartController();
      expect(c.isFull, isTrue);
      expect(c.canZoomIn, isTrue);
      c.zoomIn();
      expect(c.window.span, closeTo(1 / 1.6, 1e-9));
      expect(c.isFull, isFalse);
      c.zoomIn();
      final two = c.window.span;
      expect(two, lessThan(1 / 1.6));
      c.zoomOut();
      expect(c.window.span, closeTo(1 / 1.6, 1e-9));
      c.reset();
      expect(c.isFull, isTrue);
      expect(c.canZoomIn, isTrue);
    });

    test('放到最小比例后 canZoomIn 变 false（按钮该置灰）', () {
      final c = ErpChartController();
      for (var i = 0; i < 40; i++) {
        c.zoomIn();
      }
      expect(c.window.span, closeTo(ChartWindow.minSpan, 1e-9));
      expect(c.canZoomIn, isFalse);
      expect(c.canZoomIn, isFalse);
    });

    test('set 会去重（同样的窗口不重复通知）', () {
      final c = ErpChartController();
      var n = 0;
      c.addListener(() => n++);
      c.set(ChartWindow.full);
      expect(n, 0, reason: '还是全览，不该通知');
      c.set(const ChartWindow(0.2, 0.6));
      expect(n, 1);
      c.set(const ChartWindow(0.2, 0.6));
      expect(n, 1, reason: '同一个窗口重复设置不通知');
    });

    // 用户 2026-09-29：「指数看板里的市场估值在缩放的时候保证右侧日期最新，
    // 只缩放左侧」—— 右端锚定，最新那天永远留在屏幕右边。
    group('右端锚定缩放', () {
      test('ChartWindow.zoomedRight：end 不动，只收左边', () {
        const w = ChartWindow(0, 1);
        final z = w.zoomedRight(2);
        expect(z.end, closeTo(1, 1e-9), reason: '右端 = 最新那天，不能动');
        expect(z.start, closeTo(0.5, 1e-9));
        expect(z.span, closeTo(0.5, 1e-9));

        // 再放大一次仍锚右边；缩小也是
        expect(z.zoomedRight(2).end, closeTo(1, 1e-9));
        expect(z.zoomedRight(0.5).end, closeTo(1, 1e-9));
      });

      test('按钮放大/缩小：右端一直是最新，且不会越界', () {
        final c = ErpChartController();
        for (var i = 0; i < 5; i++) {
          c.zoomIn();
          expect(c.window.end, closeTo(1, 1e-9), reason: '第 $i 次放大');
          expect(c.window.start, greaterThanOrEqualTo(0));
        }
        for (var i = 0; i < 5; i++) {
          c.zoomOut();
          expect(c.window.end, closeTo(1, 1e-9), reason: '第 $i 次缩小');
        }
        expect(c.isFull, isTrue);
      });

      test('已经拖到历史里时再放大：仍然保住当前可见的右端', () {
        const w = ChartWindow(0.2, 0.6);
        final z = w.zoomedRight(2);
        expect(z.end, closeTo(0.6, 1e-9), reason: '保住当前右端，不强行拽回最新');
        expect(z.span, closeTo(0.2, 1e-9));
      });
    });
  });

  group('ErpChart 渲染', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(
            body: SizedBox(height: 200, width: 320, child: child),
          ),
        );

    List<MacroRow> rows(int n) => [
          for (var i = 0; i < n; i++)
            MacroRow(
              date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
              hs300Pe: 12 + i * 0.1,
              cn10y: 1.7,
              erp: 100 / (12 + i * 0.1) - 1.7, // 利差 = 1/PE − 国债
            ),
        ];

    testWidgets('只有利差一条线也能画（关注页那张小卡就是这个用法）', (tester) async {
      await tester.pumpWidget(host(ErpChart(rows: rows(30))));
      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('叠加沪深300：对齐不上的日期不画（不插值、不补零）也不崩', (tester) async {
      final points = [
        for (var i = 0; i < 20; i++)
          NavPoint(
            code: 'sh000300',
            date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
            nav: 4000 + i * 10,
          ),
      ];
      await tester.pumpWidget(host(ErpChart(
        rows: rows(30),
        indexSeries: points, // 只覆盖前 20 天，后 10 天没有
        interactive: true,
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('可交互时：拖动与缩放都不崩（自绘 + 手势）', (tester) async {
      await tester.pumpWidget(host(ErpChart(
        rows: rows(60),
        indexSeries: [
          for (var i = 0; i < 60; i++)
            NavPoint(
              code: 'sh000300',
              date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
              nav: 4000 + i * 12,
            ),
        ],
        interactive: true,
      )));
      await tester.pumpAndSettle();

      // 单指拖动（平移）
      await tester.drag(find.byType(CustomPaint).first, const Offset(-40, 0));
      await tester.pump();
      // 双指缩放
      final center = tester.getCenter(find.byType(CustomPaint).first);
      final g1 = await tester.startGesture(center - const Offset(30, 0));
      final g2 = await tester.startGesture(center + const Offset(30, 0));
      await g1.moveBy(const Offset(-20, 0));
      await g2.moveBy(const Offset(20, 0));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();
      // 双击复位
      await tester.tap(find.byType(CustomPaint).first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(CustomPaint).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('样本太少时给一句话，不画半张图', (tester) async {
      await tester.pumpWidget(host(ErpChart(rows: rows(1))));
      await tester.pumpAndSettle();
      expect(find.textContaining('再攒几天'), findsOneWidget);
    });
  });
}
