import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/portfolio.dart';
import 'package:invest_tracker/ui/holdings_page.dart';

/// 持仓卡片：设计稿 `pic/cc.jpg` 的口径与版式
///
/// 卡片被拆成「数据（[HoldingCardData]）+ 展示（[HoldingCard]）」，
/// 所以那些容易写错的口径规则可以脱离界面直接单测。
void main() {
  final asset = Asset(
    id: 1,
    code: '022459',
    name: '易方达中证A500ETF联接A',
    kind: AssetKind.fund,
  );

  /// 造一个持仓：默认「盈利」情形
  Position pos({
    double shares = 1892.67,
    double cost = 2412.0,
    double price = 1.2319,
    double prevClose = 1.2442,
    String infoDate = '2026-09-11',
    double realized = 0,
    bool withQuote = true,
  }) =>
      Position(
        accountId: 1,
        asset: asset,
        shares: shares,
        cost: cost,
        realized: realized,
        invested: cost,
        returned: 0,
        quote: withQuote
            ? Quote(
                code: asset.code,
                kind: AssetKind.fund,
                name: asset.name,
                price: price,
                prevClose: prevClose,
                changePct: (price / prevClose - 1) * 100,
                priceType: 'nav',
                infoDate: infoDate,
              )
            : null,
        txns: const [],
      );

  HoldingCardData dataFor(Position p, {double total = 100000}) =>
      HoldingCardData.from(p, totalMarketValue: total);

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('口径推导', () {
    test('市值 = 份额 × 现价；占比 = 市值 ÷ 总市值', () {
      final d = dataFor(pos(), total: 100000);
      expect(d.marketValue, closeTo(1892.67 * 1.2319, 1e-6));
      expect(d.ratio, closeTo(1892.67 * 1.2319 / 100000, 1e-9));
    });

    test('总市值为 0 时占比为 null（显示 --，不冒充 0%）', () {
      expect(dataFor(pos(), total: 0).ratio, isNull);
      expect(dataFor(pos()).ratio, isNotNull);
    });

    test('昨日收益百分比恒等于净值涨跌幅', () {
      final p = pos();
      final d = dataFor(p);
      expect(d.changePct, isNotNull);
      expect(d.dayPct, closeTo(d.changePct!, 1e-9),
          reason: 'dayPnl/(市值−dayPnl) 与 涨跌幅 数学上相等');
    });

    test('分母 ≤ 0 时昨日收益百分比为 null', () {
      // 现价 0.5、昨收 1.0 → 市值 400、dayPnl −400 → 分母 800 仍 > 0；
      // 构造分母为 0 的极端：份额为 0
      final p = pos(shares: 0, cost: 0, price: 1.0, prevClose: 1.0);
      expect(dataFor(p).dayPct, isNull);
    });

    test('无行情时所有金额降级为 null，但份额与成本仍在', () {
      final d = dataFor(pos(withQuote: false));
      expect(d.hasQuote, isFalse);
      expect(d.marketValue, 0);
      expect(d.ratio, isNull);
      expect(d.dayPnl, isNull);
      expect(d.dayPct, isNull);
      expect(d.holdingPnl, isNull);
      expect(d.cumulativePnl, isNull);
      expect(d.price, isNull);
      expect(d.changePct, isNull);
      expect(d.infoDate, '');
      // 份额与成本不依赖行情
      expect(d.shares, closeTo(1892.67, 1e-9));
      expect(d.avgCost, closeTo(2412.0 / 1892.67, 1e-6));
    });

    test('名称为空时用代码兜底', () {
      final p = Position(
        accountId: 1,
        asset: Asset(id: 2, code: '510300', name: '', kind: AssetKind.etf),
        shares: 1,
        cost: 1,
        realized: 0,
        invested: 1,
        returned: 0,
        quote: null,
        txns: const [],
      );
      expect(dataFor(p).name, '510300');
    });

    test('账户名按调用方传入决定是否带出', () {
      expect(dataFor(pos()).accountName, isNull);
      expect(
        HoldingCardData.from(pos(),
                totalMarketValue: 100000, accountName: '默认账户')
            .accountName,
        '默认账户',
      );
    });
  });

  group('市值大字的配色规则', () {
    test('跟随累计收益的正负，而不是市值本身', () {
      // 亏损：现价低于成本 → 累计收益为负 → 绿色
      final loss = dataFor(pos(price: 1.20, cost: 2412.0));
      expect(loss.cumulativePnl, lessThan(0));
      expect(loss.valueColor, const Color(0xFF1A9C5B));

      // 盈利：现价高于成本 → 累计收益为正 → 红色
      final win = dataFor(pos(price: 1.40, cost: 2412.0));
      expect(win.cumulativePnl, greaterThan(0));
      expect(win.valueColor, const Color(0xFFD93A3A));
    });

    test('累计收益为 0 时不染色', () {
      // 现价恰好等于成本单价 → 浮动为 0、无已实现 → 累计收益为 0
      final p = pos(price: 2412.0 / 1892.67, cost: 2412.0);
      final d = dataFor(p);
      expect(d.cumulativePnl, closeTo(0, 1e-9));
      expect(d.valueColor, isNull);
    });

    test('无行情时不染色（金额显示 --）', () {
      expect(dataFor(pos(withQuote: false)).valueColor, isNull);
    });
  });

  group('卡片渲染', () {
    testWidgets('七行结构齐全，金额 2 位小数', (tester) async {
      await tester.pumpWidget(host(HoldingCard(data: dataFor(pos()))));

      expect(find.text('易方达中证A500ETF联接A'), findsOneWidget);
      expect(find.text('022459'), findsOneWidget);
      expect(find.text('市值'), findsOneWidget);
      expect(find.text('占比'), findsOneWidget);
      expect(find.text('持仓收益'), findsOneWidget);
      expect(find.text('累计收益'), findsOneWidget);
      expect(find.text('份额'), findsOneWidget);
      expect(find.text('成本'), findsOneWidget);
      // 净值那行是「净值 + (涨跌幅%)」，用正则确认括号形式
      expect(find.textContaining(RegExp(r'^\([-+]?\d+\.\d\d%\)$')), findsOneWidget);
      expect(find.text('2026-09-11'), findsOneWidget);
      // 市值保留两位小数且带千分位
      expect(find.textContaining(RegExp(r'^\d{1,3}(,\d{3})*\.\d\d$')), findsWidgets);
    });

    testWidgets('收益标签固定为「当日收益」，不带日期', (tester) async {
      await tester.pumpWidget(host(HoldingCard(data: dataFor(pos()))));
      expect(find.text('当日收益'), findsOneWidget);
      // 不再拼「前日收益 09-11」这种带日期的文案
      expect(find.textContaining('收益 09-11'), findsNothing);
    });

    testWidgets('市值金额的颜色跟随累计收益', (tester) async {
      final p = pos(price: 1.20, cost: 2412.0); // 亏损
      await tester.pumpWidget(host(HoldingCard(data: dataFor(p))));

      final money = find.textContaining(RegExp(r'^1,8|^2,2|^2,3|^\d,\d{3}\.\d\d$'));
      expect(money, findsWidgets);
      final style = tester.widget<Text>(money.first).style;
      expect(style?.color, const Color(0xFF1A9C5B));
    });

    testWidgets('占比值不带涨跌色（黑色）', (tester) async {
      await tester.pumpWidget(host(HoldingCard(data: dataFor(pos()))));
      final ratio = tester.widget<Text>(
          find.textContaining(RegExp(r'^\d+\.\d%$')));
      expect(ratio.style?.color, isNull);
    });

    testWidgets('无行情时显示 -- 与「无行情」标', (tester) async {
      await tester.pumpWidget(
          host(HoldingCard(data: dataFor(pos(withQuote: false)))));

      expect(find.text('无行情'), findsOneWidget);
      // 无行情时降级为 -- 的共 10 处：
      // 市值、占比、昨日收益(金额+%)、持仓收益(金额+%)、累计收益(金额+%)、
      // 净值、净值日期
      expect(find.text('--'), findsNWidgets(10));
      // 份额与成本不依赖行情，仍应正常显示
      expect(find.text('1,892.67'), findsOneWidget);
    });

    testWidgets('传入账户名时显示灰色标签', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(),
            totalMarketValue: 100000, accountName: '默认账户'),
      )));
      expect(find.text('默认账户'), findsOneWidget);
    });

    testWidgets('点卡片触发回调', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(HoldingCard(
        data: dataFor(pos()),
        onTap: () => tapped = true,
      )));
      await tester.tap(find.byType(HoldingCard));
      expect(tapped, isTrue);
    });
  });

  group('排序行', () {
    testWidgets('四个元素齐全', (tester) async {
      await tester.pumpWidget(host(HoldingSortBar(
        sortLabel: '持仓市值',
        ascending: true,
        count: 4,
        onPickKey: () {},
        onToggleDirection: () {},
      )));

      expect(find.text('排序'), findsOneWidget);
      expect(find.text('持仓市值'), findsOneWidget);
      expect(find.text('升序'), findsOneWidget);
      expect(find.text('持有 4 只'), findsOneWidget);
    });

    testWidgets('降序时文案切换', (tester) async {
      await tester.pumpWidget(host(HoldingSortBar(
        sortLabel: '收益率',
        ascending: false,
        count: 2,
        onPickKey: () {},
        onToggleDirection: () {},
      )));
      expect(find.text('降序'), findsOneWidget);
      expect(find.text('升序'), findsNothing);
      expect(find.text('持有 2 只'), findsOneWidget);
    });

    testWidgets('两个胶囊各自触发回调', (tester) async {
      var picked = false;
      var toggled = false;
      await tester.pumpWidget(host(HoldingSortBar(
        sortLabel: '持仓市值',
        ascending: true,
        count: 1,
        onPickKey: () => picked = true,
        onToggleDirection: () => toggled = true,
      )));

      await tester.tap(find.text('持仓市值'));
      expect(picked, isTrue);
      expect(toggled, isFalse);

      await tester.tap(find.text('升序'));
      expect(toggled, isTrue);
    });

    test('排序键与设计稿文案一致', () {
      expect(HoldingSortBar.labelOf('marketValue'), '持仓市值');
      expect(HoldingSortBar.labelOf('returnPct'), '收益率');
      expect(HoldingSortBar.labelOf('dayPnl'), '当日收益');
      expect(HoldingSortBar.labelOf('cost'), '持仓成本');
      // 未知键回落到「持仓市值」，不显示成空
      expect(HoldingSortBar.labelOf('nonsense'), '持仓市值');
    });
  });
}
