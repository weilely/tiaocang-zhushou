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

  // 用户 2026-09-29：「市场估值历史曲线图沪深300收益补的数据没有显示完全」
  group('横轴 = 利差 ∪ 指数日线（补的早年数据也要有位置画）', () {
    List<MacroRow> erpRows() => [
          // 利差只有 2016-08 之后（本地回填的起点）
          MacroRow(date: '2016-08-15', hs300Pe: 12, cn10y: 2.7, erp: 5.63),
          MacroRow(date: '2016-08-16', hs300Pe: 12.1, cn10y: 2.7, erp: 5.56),
          MacroRow(date: '2026-09-29', hs300Pe: 13.09, cn10y: 1.67, erp: 5.97),
        ];

    test('指数日线早于利差起点时，轴要往前扩（否则补的数据没位置画）', () {
      final axis = erpChartAxis(erpRows(), const [
        NavPoint(code: 'sh000300', date: '2005-04-08', nav: 982.79),
        NavPoint(code: 'sh000300', date: '2016-08-15', nav: 3393.42),
      ]);
      expect(axis.dates.first, '2005-04-08', reason: '轴必须覆盖最早的指数日线');
      expect(axis.dates.last, '2026-09-29');
      expect(axis.dates, ['2005-04-08', '2016-08-15', '2016-08-16', '2026-09-29']);
      // 2005 那天只有指数、没有利差 → 利差为 null（断线，不插值）
      expect(axis.erp.first, isNull);
      expect(axis.idx.first, closeTo(982.79, 1e-9));
      expect(axis.erp[1], closeTo(5.63, 1e-9), reason: '2016-08-15 两条都有');
    });

    test('没有叠加指数时轴就是利差自己的日期（关注页那张小卡）', () {
      final axis = erpChartAxis(erpRows(), const []);
      expect(axis.dates, ['2016-08-15', '2016-08-16', '2026-09-29']);
      expect(axis.erp.every((v) => v != null), isTrue);
      expect(axis.idx, everyElement(isNull));
    });

    // 用户 2026-09-29：「沪深300收益曲线与利差曲线设置一个对齐开关，
    // 打开后多余的就不显示了」
    test('对齐开关打开：轴退回利差区间，只有指数一条线的早年那段不显示', () {
      final series = const [
        NavPoint(code: 'sh000300', date: '2005-04-08', nav: 982.79),
        NavPoint(code: 'sh000300', date: '2016-08-15', nav: 3393.42),
        NavPoint(code: 'sh000300', date: '2026-09-29', nav: 4600),
      ];
      final aligned = erpChartAxis(erpRows(), series, alignToErp: true);
      expect(aligned.dates.first, '2016-08-15', reason: '多余的 2005 那段不占轴');
      expect(aligned.dates, ['2016-08-15', '2016-08-16', '2026-09-29']);
      expect(aligned.idx.first, closeTo(3393.42, 1e-9),
          reason: '对齐后指数线从利差起点那天开始');
      expect(aligned.erp.every((v) => v != null), isTrue);

      // 关掉时仍然是并集（补的数据要看得到）
      final full = erpChartAxis(erpRows(), series, alignToErp: false);
      expect(full.dates.first, '2005-04-08');
      expect(full.erp.first, isNull);
    });

    test('两条序列的日期交错时合并成一条有序轴，各取各的值', () {
      final axis = erpChartAxis(
        [
          const MacroRow(date: '2026-01-02', hs300Pe: 12, cn10y: 2, erp: 6.33),
          const MacroRow(date: '2026-01-05', hs300Pe: 12, cn10y: 2, erp: 6.33),
        ],
        const [
          NavPoint(code: 'sh000300', date: '2026-01-03', nav: 4000),
          NavPoint(code: 'sh000300', date: '2026-01-05', nav: 4100),
        ],
      );
      expect(axis.dates, ['2026-01-02', '2026-01-03', '2026-01-05']);
      expect(axis.erp[1], closeTo(6.33, 1e-9),
          reason: '01-03 利差没数据 → 前向填充 01-02 的值（不留洞）');
      expect(axis.idx[0], isNull,
          reason: '01-02 早于指数序列的第一天（01-03）→ 还没出生，不给值');
      expect(axis.idx[1], closeTo(4000, 1e-9));
      expect(axis.idx[2], closeTo(4100, 1e-9));
    });

    // 用户 2026-09-29：「为什么沪深300收益曲线放大后不连续」
    // 实测他的库里：2958 个利差日里有 500 天对不上沪深300 日线（461 天是周末，
    // 其余是中秋/国庆这类休市日）→ 只按同一天精确命中就会画出满地断点。
    test('周末 / 假期不留洞：某天没有新数据就沿用最近一个（前向填充）', () {
      // 周五、周六、周日（利差每天都有；指数只有周五）
      final axis = erpChartAxis(
        const [
          MacroRow(date: '2026-09-25', hs300Pe: 13, cn10y: 1.67, erp: 6.02),
          MacroRow(date: '2026-09-26', hs300Pe: 13, cn10y: 1.66, erp: 6.03),
          MacroRow(date: '2026-09-27', hs300Pe: 13, cn10y: 1.66, erp: 6.04),
          MacroRow(date: '2026-09-28', hs300Pe: 13, cn10y: 1.67, erp: 6.02),
        ],
        const [
          NavPoint(code: 'sh000300', date: '2026-09-25', nav: 4600),
          NavPoint(code: 'sh000300', date: '2026-09-28', nav: 4560),
        ],
      );
      expect(axis.idx, everyElement(isNotNull),
          reason: '周末要沿用周五收盘，不能留 null（否则曲线一段段断掉）');
      expect(axis.idx[0], closeTo(4600, 1e-9));
      expect(axis.idx[1], closeTo(4600, 1e-9), reason: '周六 = 周五的值');
      expect(axis.idx[2], closeTo(4600, 1e-9), reason: '周日 = 周五的值');
      expect(axis.idx[3], closeTo(4560, 1e-9), reason: '周一有新数据就用新的');
    });

    test('前向填充不做过头：各自序列开始之前仍然是 null', () {
      final axis = erpChartAxis(
        const [MacroRow(date: '2016-08-15', hs300Pe: 12, cn10y: 2.7, erp: 5.6)],
        const [
          NavPoint(code: 'sh000300', date: '2005-04-08', nav: 982.79),
          NavPoint(code: 'sh000300', date: '2016-08-15', nav: 3393.42),
        ],
      );
      expect(axis.dates.first, '2005-04-08');
      expect(axis.erp.first, isNull, reason: '利差 2016 才开始，2005 那天不能填出值');
      expect(axis.idx.first, closeTo(982.79, 1e-9));
    });

    test('缺口超过 $kErpFillMaxDays 天就不补：那是真缺数据，不能画成一条平线', () {
      final axis = erpChartAxis(
        const [
          MacroRow(date: '2026-01-05', hs300Pe: 12, cn10y: 2, erp: 6.33),
          // 指数从 2025-01-05 一口气断到 2026-01-05 才有下一条
          MacroRow(date: '2026-01-06', hs300Pe: 12, cn10y: 2, erp: 6.33),
        ],
        const [
          NavPoint(code: 'sh000300', date: '2025-01-05', nav: 3800),
        ],
      );
      // 轴上有 2025-01-05（并集），但 2026-01-05 距上一个值 365 天 → 不补
      expect(axis.idx.last, isNull, reason: '365 天的空洞要如实断开');
      expect(axis.idx.first, closeTo(3800, 1e-9));
    });

    testWidgets('补了早年的指数日线也照常渲染、不崩', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            width: 320,
            child: ErpChart(
              rows: [
                for (var m = 1; m <= 12; m++)
                  MacroRow(
                    date: '2026-${m.toString().padLeft(2, '0')}-15',
                    hs300Pe: 12,
                    cn10y: 2,
                    erp: 6.33,
                  ),
              ],
              // 指数从 2005 起，利差只到 2026 —— 轴会长很多
              indexSeries: [
                for (var y = 2005; y <= 2026; y++)
                  NavPoint(
                    code: 'sh000300',
                    date: '$y-06-15',
                    nav: 1000 + (y - 2005) * 150,
                  ),
              ],
              interactive: true,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // 用户 2026-09-29：「两条线颜色区分不明显」
  group('两条线的配色要能一眼分开', () {
    test('叠加线不能再用蓝色系（主线的主题蓝 #1F6FEB 与它就差十几度色相）', () {
      const primary = Color(0xFF1F6FEB); // 股债利差那条线（theme.colorScheme.primary）
      final dHue =
          (HSLColor.fromColor(kErpIndexLine).hue - HSLColor.fromColor(primary).hue)
              .abs();
      final gap = dHue > 180 ? 360 - dHue : dHue;
      expect(gap, greaterThan(60),
          reason: '色相差只有 ${gap.toStringAsFixed(1)}° 就会被看成一回事');
      // 明度也要拉开，别靠"同色不同深浅"糊过去
      final dL = (HSLColor.fromColor(kErpIndexLine).lightness -
              HSLColor.fromColor(primary).lightness)
          .abs();
      expect(dL, greaterThan(0.05));
    });

    test('和图例 / 右轴刻度用的是同一个颜色（对得上哪条线看哪个轴）', () {
      expect(kErpIndexLine, const Color(0xFFE8A33D));
    });
  });
}
