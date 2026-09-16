import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/benchmark.dart';
import 'package:invest_tracker/logic/cash_flow.dart';
import 'package:invest_tracker/logic/range_preset.dart';
import 'package:invest_tracker/logic/returns_calendar.dart';
import 'package:invest_tracker/ui/widgets/cash_flow_map.dart';
import 'package:invest_tracker/ui/widgets/pnl_calendar.dart';
import 'package:invest_tracker/ui/widgets/returns_stats_card.dart';

/// 收益统计卡片：三页签的文案、顺序与资金流导图的上下关系
void main() {
  CashFlowStatement statement({
    double beginHolding = 80000,
    double beginCash = 10000,
    double endHolding = 85000,
    double endCash = 12000,
    double deposit = 20000,
    double withdraw = 5000,
    double investAmount = 30000,
    double redeemAmount = 8000,
    double dividend = 320.5,
    double cashIncome = 46.2,
    double cashAdjust = 0,
  }) =>
      CashFlowStatement(
        range: DateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
        beginHolding: beginHolding,
        beginCash: beginCash,
        endHolding: endHolding,
        endCash: endCash,
        deposit: deposit,
        withdraw: withdraw,
        investAmount: investAmount,
        redeemAmount: redeemAmount,
        dividend: dividend,
        cashIncome: cashIncome,
        cashAdjust: cashAdjust,
      );

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  group('资金流导图', () {
    testWidgets('七个节点齐全，且金额保留 2 位小数、带千分位', (tester) async {
      await tester.pumpWidget(host(CashFlowMap(s: statement())));

      for (final label in [
        '期初资产',
        '投入金额',
        '赎回金额',
        '净流入',
        '账户盈亏',
        '现金分红',
        '期末资产',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少节点「$label」');
      }

      // 期末资产 = 85000 + 12000
      expect(find.text('¥97,000.00'), findsOneWidget);
      // 期初资产 = 80000 + 10000
      expect(find.text('¥90,000.00'), findsOneWidget);
      // 净流入 = 20000 − 5000
      expect(find.text('+¥15,000.00'), findsOneWidget);
      expect(find.text('¥320.50'), findsOneWidget, reason: '现金分红 2 位小数');
      // 算式也要展示出来，让人一眼看出数字怎么来的
      expect(find.textContaining('充值 ¥20,000.00 − 提现 ¥5,000.00'), findsOneWidget);
      expect(find.textContaining('期间买入含手续费'), findsOneWidget);
      expect(find.textContaining('期间卖出净额'), findsOneWidget);
      expect(find.textContaining('已计入期末资产'), findsOneWidget);
    });

    testWidgets('现金分红在期末资产正上方', (tester) async {
      await tester.pumpWidget(host(CashFlowMap(s: statement())));

      final dividendY = tester.getTopLeft(find.text('现金分红')).dy;
      final endY = tester.getTopLeft(find.text('期末资产')).dy;
      expect(dividendY, lessThan(endY),
          reason: '现金分红必须显示在期末资产上方（$dividendY < $endY）');
    });

    testWidgets('节点自上而下的顺序符合方案', (tester) async {
      await tester.pumpWidget(host(CashFlowMap(s: statement())));

      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('期初资产'), lessThan(y('投入金额')));
      expect(y('投入金额'), lessThan(y('赎回金额')));
      expect(y('赎回金额'), lessThan(y('净流入')));
      expect(y('净流入'), lessThan(y('账户盈亏')));
      expect(y('账户盈亏'), lessThan(y('现金分红')));
      expect(y('现金分红'), lessThan(y('期末资产')));
    });

    testWidgets('净流出时标签自动切换', (tester) async {
      await tester.pumpWidget(host(CashFlowMap(
        s: statement(deposit: 1000, withdraw: 9000),
      )));
      expect(find.text('净流出'), findsOneWidget);
      expect(find.text('净流入'), findsNothing);
      expect(find.text('-¥8,000.00'), findsOneWidget);
    });

    testWidgets('有现金调整时加脚注', (tester) async {
      await tester.pumpWidget(host(CashFlowMap(
        s: statement(cashAdjust: -12.5),
      )));
      // 脚注是一个整体 Text，find.text 是精确匹配，所以要给全串
      expect(find.text('含现金调整 -¥12.50'), findsOneWidget);
      expect(find.text('含现金调整'), findsNothing);
    });

    testWidgets('缺净值的持仓加「含成本估值」脚注', (tester) async {
      final s = CashFlowStatement(
        range: DateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
        beginHolding: 1000,
        beginCash: 0,
        endHolding: 1000,
        endCash: 0,
        deposit: 0,
        withdraw: 0,
        investAmount: 0,
        redeemAmount: 0,
        dividend: 0,
        cashIncome: 0,
        cashAdjust: 0,
        beginMissingNav: const ['025497', '510300'],
        endMissingNav: const ['025497'],
      );
      await tester.pumpWidget(host(CashFlowMap(s: s)));
      expect(find.text('含成本估值：025497、510300'), findsOneWidget);
      expect(find.text('含成本估值：025497'), findsOneWidget);
    });
  });

  group('盈亏日历', () {
    testWidgets('日粒度：星期表头 + 每格日期与金额，盈利红亏损绿', (tester) async {
      final cells = <PnlCell>[
        const PnlCell(label: ''),
        const PnlCell(label: ''),
        const PnlCell(label: '1', amount: 1844),
        const PnlCell(label: '2', amount: -335),
        for (var d = 3; d <= 30; d++) PnlCell(label: '$d'),
        for (var i = 0; i < 10; i++) const PnlCell(label: ''),
      ];
      await tester.pumpWidget(host(PnlCalendar(
        cells: cells,
        granularity: ReturnGranularity.day,
      )));

      for (final w in PnlCalendar.weekdayLabels) {
        expect(find.text(w), findsOneWidget);
      }
      expect(find.text('1,844'), findsOneWidget);
      expect(find.text('-335'), findsOneWidget, reason: '亏损保留负号，不只靠颜色');

      final winColor = tester
          .widget<Text>(find.text('1,844'))
          .style
          ?.color;
      final lossColor = tester
          .widget<Text>(find.text('-335'))
          .style
          ?.color;
      expect(winColor, const Color(0xFFD93A3A));
      expect(lossColor, const Color(0xFF1A9C5B));
    });

    testWidgets('没有数据的格子只显示标签，不显示 0', (tester) async {
      // 42 格：前导空位 + 1..30 + 尾部空位，标签唯一
      final cells = <PnlCell>[
        const PnlCell(label: ''),
        const PnlCell(label: ''),
        for (var d = 1; d <= 30; d++) PnlCell(label: '$d'),
        for (var i = 0; i < 10; i++) const PnlCell(label: ''),
      ];
      await tester.pumpWidget(host(PnlCalendar(
        cells: cells,
        granularity: ReturnGranularity.day,
      )));
      expect(cells.length, 42);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('0.00'), findsNothing);
    });

    testWidgets('月粒度显示 1月…12月且隐藏星期表头', (tester) async {
      await tester.pumpWidget(host(PnlCalendar(
        cells: [
          for (var m = 1; m <= 12; m++) PnlCell(label: '$m月', amount: m * 100.0),
        ],
        granularity: ReturnGranularity.month,
      )));
      expect(find.text('1月'), findsOneWidget);
      expect(find.text('12月'), findsOneWidget);
      expect(find.text('日'), findsNothing, reason: '月粒度不该有星期表头');
      expect(find.text('1,200'), findsOneWidget);
    });
  });

  group('图例', () {
    testWidgets('显示盈利与亏损两项', (tester) async {
      await tester.pumpWidget(host(const PnlLegend()));
      expect(find.text('盈利'), findsOneWidget);
      expect(find.text('亏损'), findsOneWidget);
    });
  });

  group('日历格：热力底色、无边框', () {
    /// 取某个文本最近的 Container（就是格子本体）
    BoxDecoration cellDeco(WidgetTester tester, String text) {
      final c = tester.widget<Container>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Container))
            .first,
      );
      return c.decoration! as BoxDecoration;
    }

    testWidgets('盈利格浅红底、亏损格浅绿底，且都没有边框', (tester) async {
      await tester.pumpWidget(host(PnlCalendar(
        cells: [
          const PnlCell(label: ''),
          const PnlCell(label: ''),
          const PnlCell(label: '1', amount: 1844),
          const PnlCell(label: '2', amount: -335),
          for (var d = 3; d <= 30; d++) PnlCell(label: '$d'),
          for (var i = 0; i < 10; i++) const PnlCell(label: ''),
        ],
        granularity: ReturnGranularity.day,
      )));

      final win = cellDeco(tester, '1,844');
      final loss = cellDeco(tester, '-335');

      expect(win.color, const Color(0xFFD93A3A).withValues(alpha: 0.12));
      expect(loss.color, const Color(0xFF1A9C5B).withValues(alpha: 0.12));
      expect(win.border, isNull, reason: '设计稿的格子没有边框');
      expect(loss.border, isNull);
    });

    testWidgets('没有数据的格子没有底色', (tester) async {
      await tester.pumpWidget(host(PnlCalendar(
        cells: [
          const PnlCell(label: ''),
          const PnlCell(label: ''),
          const PnlCell(label: '1', amount: 1844),
          for (var d = 2; d <= 30; d++) PnlCell(label: '$d'),
          for (var i = 0; i < 10; i++) const PnlCell(label: ''),
        ],
        granularity: ReturnGranularity.day,
      )));

      expect(cellDeco(tester, '5').color, isNull);
      expect(cellDeco(tester, '5').border, isNull);
      expect(cellDeco(tester, '1,844').color, isNotNull);
    });
  });

  group('区间合计行（日历图的「累计收益」）', () {
    testWidgets('正数带 + 号与涨色', (tester) async {
      await tester.pumpWidget(host(const PeriodTotalRow(amount: 6763.0)));
      final t = tester.widget<Text>(find.text('+¥6,763.00'));
      expect(t.style?.color, const Color(0xFFD93A3A));
    });

    testWidgets('负数用跌色（设计稿那行就是绿色的负数）', (tester) async {
      await tester.pumpWidget(host(const PeriodTotalRow(amount: -5217.03)));
      final t = tester.widget<Text>(find.text('-¥5,217.03'));
      expect(t.style?.color, const Color(0xFF1A9C5B));
    });

    testWidgets('null 显示 -- 而不是 ¥0.00', (tester) async {
      await tester.pumpWidget(host(const PeriodTotalRow(amount: null)));
      expect(find.text('--'), findsOneWidget);
      expect(find.textContaining('¥0.00'), findsNothing);
    });

    testWidgets('真的为 0 时显示 ¥0.00', (tester) async {
      await tester.pumpWidget(host(const PeriodTotalRow(amount: 0)));
      expect(find.text('¥0.00'), findsOneWidget);
      expect(find.text('--'), findsNothing);
    });
  });

  group('区间筹码', () {
    testWidgets('主筹码 + 更多；点更多弹出其余预设', (tester) async {
      RangePreset? picked;
      await tester.pumpWidget(host(PresetChips(
        presets: flowMainPresets,
        selected: RangePreset.month,
        morePresets: flowMorePresets,
        onSelected: (p) => picked = p,
        onCustom: () {},
      )));

      expect(find.text('当月'), findsOneWidget);
      expect(find.text('今年'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('更多'), findsOneWidget);

      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();

      expect(find.text('近3月'), findsOneWidget);
      expect(find.text('近6月'), findsOneWidget);
      expect(find.text('近1年'), findsOneWidget);
      expect(find.text('近3年'), findsOneWidget);
      expect(find.text('自定义区间'), findsOneWidget);

      await tester.tap(find.text('近3月'));
      await tester.pumpAndSettle();
      expect(picked, RangePreset.m3);
    });

    testWidgets('选中的是「更多」里的项时，筹码位显示该项名字', (tester) async {
      await tester.pumpWidget(host(PresetChips(
        presets: flowMainPresets,
        selected: RangePreset.y1,
        morePresets: flowMorePresets,
        onSelected: (_) {},
        onCustom: () {},
      )));
      expect(find.text('近1年'), findsOneWidget);
      expect(find.text('更多'), findsNothing);
    });

    testWidgets('点自定义区间走回调而不是 onSelected', (tester) async {
      var custom = false;
      RangePreset? picked;
      await tester.pumpWidget(host(PresetChips(
        presets: flowMainPresets,
        selected: RangePreset.month,
        morePresets: flowMorePresets,
        onSelected: (p) => picked = p,
        onCustom: () => custom = true,
      )));

      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义区间'));
      await tester.pumpAndSettle();

      expect(custom, isTrue);
      expect(picked, isNull, reason: '自定义区间不该触发普通选中回调');
    });
  });

  group('基准模型在界面上的文案', () {
    test('自定义年化与大盘指数的图例名不同', () {
      expect(const Benchmark(annualPct: 3).legendName, '参考收益');
      expect(
        const Benchmark(
          kind: BenchmarkKind.marketIndex,
          indexCode: 'sh000300',
          indexName: '沪深300',
        ).legendName,
        '沪深300',
      );
    });
  });
}
