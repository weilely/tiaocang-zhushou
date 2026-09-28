import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/data/stock_detail.dart';
import 'package:invest_tracker/ui/stock_profile_page.dart';

/// 股票资料页：版式 + 各种状态（资料齐全 / 没分红 / 三块全空降级 / 接口挂了）
///
/// 取数走注入口（[StockProfilePage.loader] / [StockProfilePage.historyLoader]）——
/// widget 测试里没有 sqflite/网络，直接读 AppState 会炸。
void main() {
  final now = DateTime(2026, 9, 28, 10, 30);

  List<NavPoint> history() => [
        const NavPoint(code: '000001', date: '2026-09-23', nav: 10.42),
        const NavPoint(code: '000001', date: '2026-09-24', nav: 10.52),
        const NavPoint(code: '000001', date: '2026-09-25', nav: 10.61),
      ];

  StockDetailBundle full() => StockDetailBundle(
        code: '000001',
        valuation: const StockValuation(
          thscode: '000001.SZ',
          ticker: '000001',
          name: '平安银行',
          peTtm: 5.045833,
          peMrq: 4.266946,
          pbMrq: 0.468348,
          psTtm: 1.652825,
          pcfTtm: 0.615649,
        ),
        financials: StockFinancials(
          thscode: '000001.SZ',
          report: '2026-2',
          abilities: [
            StockAbility(ability: 'growth', indicators: [
              const StockIndicator(
                  indexId: 'calculate_operating_income_yoy_growth_ratio',
                  raw: '1.77560000',
                  num: 1.7756),
              const StockIndicator(
                  indexId: 'total_assets_growth_ratio', raw: '1.7383', num: 1.7383),
            ]),
            StockAbility(ability: 'profitability', indicators: [
              const StockIndicator(
                  indexId: 'index_weighted_avg_roe', raw: '5.2200', num: 5.22),
            ]),
            StockAbility(ability: 'solvency', indicators: [
              const StockIndicator(
                  indexId: 'assets_debt_ratio', raw: '90.9067', num: 90.9067),
              // 银行没有流动比率 → 界面必须**跳过**，别画成 --
              const StockIndicator(indexId: 'current_ratio', raw: '', num: null),
            ]),
            StockAbility(ability: 'operation', indicators: [
              // 存货周转率也没有
              const StockIndicator(
                  indexId: 'inventory_turnover_ratio', raw: '', num: null),
              // 小于 1 的非百分比指标要保留 4 位（真机实测：0.0118 曾被截成 0.01）
              const StockIndicator(
                  indexId: 'total_assets_turnover_ratio',
                  raw: '0.0118',
                  num: 0.0118),
            ]),
          ],
        ),
        dividends: [
          StockDividendEvent(
            exDate: DateTime(2026, 9, 23),
            dividendPerShare: 0.249,
            perShareBonus: 0,
          ),
          StockDividendEvent(
            exDate: DateTime(2026, 6, 12),
            dividendPerShare: 0.36,
            perShareBonus: 0.3,
          ),
        ],
        fetchedAt: now,
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

  Widget page({
    required StockDetailBundle Function() bundle,
    List<NavPoint>? navs,
  }) =>
      StockProfilePage(
        code: '000001',
        name: '平安银行',
        kind: AssetKind.stock,
        loader: (_) async => bundle(),
        historyLoader: () async => navs ?? history(),
      );

  /// 历史净值卡在长列表**底部**：ListView 懒加载，不滚到可见就不会被构建
  /// （不是页面没渲染 —— 真机上下滑就能看到）
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find.byType(Scrollable).first,
    );
  }

  testWidgets('资料齐全：估值 / 财务指标 / 分红送配 / 历史净值 都在', (tester) async {
    await tester.pumpWidget(host(page(bundle: full)));
    await tester.pumpAndSettle();

    // 标题带类型
    expect(find.text('000001 · 股票资料'), findsOneWidget);
    expect(find.text('估值'), findsOneWidget);
    expect(find.text('PE(TTM)'), findsOneWidget);
    expect(find.text('5.05'), findsOneWidget);
    expect(find.text('0.47'), findsOneWidget); // PB

    expect(find.text('财务指标'), findsOneWidget);
    expect(find.text('报告期 2026-2'), findsOneWidget);
    expect(find.text('净资产收益率'), findsOneWidget);
    expect(find.text('5.22%'), findsOneWidget);
    expect(find.text('资产负债率'), findsOneWidget);
    expect(find.text('90.91%'), findsOneWidget);
    // ★ 标注（文档未收录中文名的那几项）
    expect(find.text('营业收入同比增长率 ★'), findsOneWidget);

    expect(find.text('分红送配'), findsOneWidget);
    expect(find.textContaining('每股分红 0.249 元'), findsOneWidget);
    expect(find.textContaining('每股送 0.3 股'), findsOneWidget);

    await scrollTo(tester, find.text('历史净值'));
    expect(find.text('历史净值'), findsOneWidget);
    expect(find.textContaining('最新'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('值为空的指标要跳过（银行没有存货/流动比率），不能画成 --；小于 1 的指标保留 4 位小数',
      (tester) async {
    await tester.pumpWidget(host(page(bundle: full)));
    await tester.pumpAndSettle();
    expect(find.text('流动比率'), findsNothing);
    expect(find.text('存货周转率'), findsNothing);
    // 有值的组照常显示
    expect(find.text('偿债'), findsOneWidget);
    expect(find.text('营运'), findsOneWidget);
    // 0.0118 不能被截成 0.01（真机实测踩到过）
    expect(find.text('0.0118'), findsOneWidget);
    expect(find.text('0.01'), findsNothing);
  });

  testWidgets('三块全空 → 降级成"没有资料数据 + 历史净值列表"', (tester) async {
    await tester.pumpWidget(host(page(
      bundle: () => StockDetailBundle(
        code: '000001',
        valuationError: '这只股票没有估值数据（同花顺未覆盖）',
        financialsError: '没有取到财务指标',
        dividendsError: '同花顺请求超时',
        fetchedAt: now,
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('这只股票没有资料数据'), findsOneWidget);
    // 三个错误原因分开说（"没取到"≠"没有"）
    expect(find.textContaining('估值：这只股票没有估值数据'), findsOneWidget);
    expect(find.textContaining('财务：没有取到财务指标'), findsOneWidget);
    expect(find.textContaining('分红：同花顺请求超时'), findsOneWidget);
    // 直接展开历史净值（滚到底部：列表懒加载）
    await scrollTo(tester, find.text('历史净值'));
    expect(find.text('历史净值'), findsOneWidget);
    await scrollTo(tester, find.text('2026-09-25'));
    expect(find.text('2026-09-25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('接口挂了（比如没配 Key）：给原因 + 重试，且仍能看历史净值', (tester) async {
    await tester.pumpWidget(host(StockProfilePage(
      code: '000001',
      name: '平安银行',
      kind: AssetKind.stock,
      loader: (_) async => throw Exception('未配置同花顺 API Key（设置 → 同花顺数据源）'),
      historyLoader: () async => history(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('没取到资料'), findsOneWidget);
    expect(find.textContaining('未配置同花顺 API Key'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('历史净值'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分红一次都没有：说"没查到"，不是"没取到"', (tester) async {
    final b = full();
    await tester.pumpWidget(host(page(
      bundle: () => StockDetailBundle(
        code: '000001',
        valuation: b.valuation,
        financials: b.financials,
        dividends: const [],
        fetchedAt: now,
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('没有查到分红送配记录'), findsOneWidget);
  });

  testWidgets('窄屏 320dp + 字体 1.3 不溢出', (tester) async {
    await tester.pumpWidget(host(page(bundle: full), width: 320, scale: 1.3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('估值'), findsOneWidget);
  });

  testWidgets('历史净值为空时不崩，给一句提示', (tester) async {
    await tester.pumpWidget(host(page(bundle: full, navs: const [])));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.textContaining('还没有历史净值'));
    expect(find.textContaining('还没有历史净值'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
