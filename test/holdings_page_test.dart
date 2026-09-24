import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
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

  group('卡片渲染（按参考图：名称与代码 → 资产＋状态标签 → 内嵌块里左指标右曲线）', () {
    testWidgets('结构齐全，旧版式字段已移走', (tester) async {
      await tester.pumpWidget(host(HoldingCard(data: dataFor(pos()))));

      expect(find.text('易方达中证A500ETF联接A'), findsOneWidget);
      expect(find.text('022459'), findsOneWidget);
      // 右侧箭头提示"可点进详情"
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      expect(find.text('资产'), findsOneWidget);
      for (final k in [
        '最新净值',
        '净值日期',
        '当日收益',
        '持仓收益',
        '持仓收益率',
        '累计收益',
        '资产占比',
      ]) {
        expect(find.text(k), findsOneWidget, reason: '内嵌块里要有「$k」');
      }

      // 旧版式的字段不再出现在卡片上（份额/成本在「持仓详情」里看）
      expect(find.text('市值'), findsNothing);
      expect(find.text('占比'), findsNothing);
      expect(find.text('份额'), findsNothing);
      expect(find.text('成本'), findsNothing);

      // 净值日期 + 金额格式
      expect(find.text('2026-09-11'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d{1,3}(,\d{3})*\.\d\d$')),
          findsWidgets);
      // 最新净值带涨跌幅：(+0.51%) 之类
      expect(find.textContaining(RegExp(r'^\([-+]?\d+\.\d\d%\)$')),
          findsOneWidget);
    });

    testWidgets('右上角状态标签：已公布净值且不落后于历史 → 收益已更新', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(),
            totalMarketValue: 100000,
            navs: [
              NavPoint(code: '022459', date: '2026-09-10', nav: 1.2300),
              NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319),
            ]),
      )));
      expect(find.text('收益已更新'), findsOneWidget);
    });

    testWidgets('历史净值比行情新 → 收益待更新（不硬写"已更新"）', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(infoDate: '2026-09-10'),
            totalMarketValue: 100000,
            navs: [
              NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319),
            ]),
      )));
      expect(find.text('收益待更新'), findsOneWidget);
      expect(find.text('收益已更新'), findsNothing);
    });

    testWidgets('估值模式保留：有预估时显示「预估涨幅 · 预估收益」跑马灯', (tester) async {
      final p = pos()..estChangePct = 1.23;
      p.estDayPnl = 45.67;
      await tester.pumpWidget(host(HoldingCard(data: dataFor(p))));

      expect(find.textContaining('预估涨幅'), findsOneWidget);
      expect(find.textContaining('预估收益'), findsOneWidget);
      // 有估值时状态标签要说明这是估值，不是已公布净值
      expect(find.text('盘中估值'), findsOneWidget);
    });

    testWidgets('有历史净值时画「今年以来收益率」曲线', (tester) async {
      final navs = [
        NavPoint(code: '022459', date: '2025-12-31', nav: 1.10),
        NavPoint(code: '022459', date: '2026-06-30', nav: 1.20),
        NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319),
      ];
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(),
            totalMarketValue: 100000, navs: navs),
      )));
      expect(find.text('今年以来收益率'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('历史不够（只有一条）→ 不画曲线，也不写口径', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(),
            totalMarketValue: 100000,
            navs: [NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319)]),
      )));
      expect(find.text('今年以来收益率'), findsNothing);
    });

    testWidgets('资产金额的颜色跟随累计收益', (tester) async {
      final p = pos(price: 1.20, cost: 2412.0); // 亏损
      await tester.pumpWidget(host(HoldingCard(data: dataFor(p))));

      final money = find.textContaining(RegExp(r'^\d{1,3}(,\d{3})*\.\d\d$'));
      expect(money, findsWidgets);
      final style = tester.widget<Text>(money.first).style;
      expect(style?.color, const Color(0xFF1A9C5B));
    });

    testWidgets('资产占比值不带涨跌色（黑色）', (tester) async {
      await tester.pumpWidget(host(HoldingCard(data: dataFor(pos()))));
      final ratio =
          tester.widget<Text>(find.textContaining(RegExp(r'^\d+\.\d%$')));
      expect(ratio.style?.color, isNull);
    });

    testWidgets('无行情时显示 -- 与「无行情」标', (tester) async {
      await tester.pumpWidget(
          host(HoldingCard(data: dataFor(pos(withQuote: false)))));

      expect(find.text('无行情'), findsOneWidget);
      // 内嵌块里降级为 -- 的共 8 处：资产、最新净值、净值日期、
      // 当日收益、持仓收益、持仓收益率、累计收益、资产占比
      expect(find.text('--'), findsNWidgets(8));
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

    testWidgets('窄屏（320dp）+ 字体 1.3 倍：整张卡不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final navs = [
        NavPoint(code: '022459', date: '2025-12-31', nav: 1.10),
        NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319),
      ];
      await tester.pumpWidget(MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HoldingCard(
              data: HoldingCardData.from(pos(),
                  totalMarketValue: 100000, navs: navs),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '用户手机是窄屏 + 大字体，这里不许 RenderFlex overflow');
    });
  });

  group('股票 / ETF 与场外基金和谐相处（2026-09-24）', () {
    /// 场内的持仓：行情是**实时价**（priceType=price），本地日线可能还没抓到
    Position stockPos() => Position(
          accountId: 1,
          asset: Asset(
            id: 9,
            code: '600519',
            name: '贵州茅台',
            kind: AssetKind.stock,
            market: 'SH',
          ),
          shares: 100,
          cost: 150000,
          realized: 0,
          invested: 150000,
          returned: 0,
          quote: Quote(
            code: '600519',
            kind: AssetKind.stock,
            name: '贵州茅台',
            price: 1680,
            prevClose: 1660,
            changePct: 1.2,
            priceType: 'price',
            infoDate: '2026-09-24',
          ),
          txns: const [],
        );

    testWidgets('标签按类型走：最新价 / 行情日期，不再写「最新净值」', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(stockPos(), totalMarketValue: 168000),
      )));
      expect(find.text('最新价'), findsOneWidget);
      expect(find.text('行情日期'), findsOneWidget);
      expect(find.text('最新净值'), findsNothing);
      expect(find.text('净值日期'), findsNothing);
    });

    testWidgets('行情是实时价 → 收益已更新（不因"本地还没日线"误报待更新）', (tester) async {
      // 这条正是旧版的 bug：场内没有本地净值历史 → 回落判 priceType=='nav' → 判否
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(stockPos(), totalMarketValue: 168000),
      )));
      expect(find.text('收益已更新'), findsOneWidget);
      expect(find.text('收益待更新'), findsNothing);
    });

    testWidgets('场内不显示「盘中估值」（有实时价，没有预估一说）', (tester) async {
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(stockPos(), totalMarketValue: 168000),
      )));
      expect(find.text('盘中估值'), findsNothing);
      expect(find.textContaining('预估涨幅'), findsNothing);
    });

    testWidgets('有日线时曲线标题写「涨跌幅」（价格口径），基金仍是「收益率」', (tester) async {
      final navs = [
        NavPoint(code: '600519', date: '2025-12-31', nav: 1500),
        NavPoint(code: '600519', date: '2026-06-30', nav: 1600),
        NavPoint(code: '600519', date: '2026-09-24', nav: 1680),
      ];
      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(stockPos(),
            totalMarketValue: 168000, navs: navs),
      )));
      expect(find.text('今年以来涨跌幅'), findsOneWidget);
      expect(find.text('今年以来收益率'), findsNothing);

      await tester.pumpWidget(host(HoldingCard(
        data: HoldingCardData.from(pos(),
            totalMarketValue: 100000,
            navs: [
              NavPoint(code: '022459', date: '2025-12-31', nav: 1.10),
              NavPoint(code: '022459', date: '2026-06-30', nav: 1.20),
              NavPoint(code: '022459', date: '2026-09-11', nav: 1.2319),
            ]),
      )));
      expect(find.text('今年以来收益率'), findsOneWidget);
    });

    testWidgets('股票卡窄屏 320dp + 字体 1.3 倍也不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final navs = [
        NavPoint(code: '600519', date: '2025-12-31', nav: 1500),
        NavPoint(code: '600519', date: '2026-09-24', nav: 1680),
      ];
      await tester.pumpWidget(MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HoldingCard(
              data: HoldingCardData.from(stockPos(),
                  totalMarketValue: 168000, navs: navs),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
