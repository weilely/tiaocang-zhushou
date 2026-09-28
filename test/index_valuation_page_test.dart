import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_indicator.dart';
import 'package:invest_tracker/data/csi_perf.dart';
import 'package:invest_tracker/data/index_catalog.dart';
import 'package:invest_tracker/data/index_eva.dart';
import 'package:invest_tracker/ui/index_valuation_page.dart';

/// 指数估值页（通用模版）：目录搜索 / 分类 / 排序 / 点开估值 / 查不到 / 联想兜底
///
/// 五个 loader 全部注入（widget 测试里没有 Provider、没有网络）。
void main() {
  // 视口按**真机**来：400dp × 880dp（默认的 800×600 太矮，靠下的卡片会被切一半，
  // 点中心会落空 —— 这是本文件踩过的坑）
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
          {String series = '中证系列指数',
          String classify = '策略',
          String assetClass = '股票',
          int? cons,
          double? mr,
          bool tracked = true}) =>
      IndexCatalogItem(
        code: code,
        name: name,
        series: series,
        classify: classify,
        assetClass: assetClass,
        region: '境内',
        currency: '人民币',
        consNumber: cons,
        monthlyReturn: mr,
        tracked: tracked,
      );

  /// 4 条目录：两条红利、一条宽基、一条上证
  IndexCatalog cat() => IndexCatalog([
        item('000922', '中证红利', cons: 100, mr: -1.20),
        item('930740', '300红利LV', classify: '策略', cons: 50, mr: 2.30),
        item('000300', '沪深300', classify: '规模', cons: 300, mr: -5.82),
        item('000001', '上证指数',
            series: '上证系列指数', classify: '规模', cons: 2000, mr: null),
      ], DateTime(2026, 9, 29));

  IndexValuation zzh() => IndexValuation(
        symbol: 'SH000922',
        name: '中证红利',
        pe: 8.6082,
        pb: 0.8485,
        yeild: 0.0426,
        roe: 0.0986,
        pePercentile: 0.7928,
        pbPercentile: 0.5032,
        windowStart: DateTime(2016, 6, 20),
        date: '2026-09-28',
        evaType: 'high',
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
    Future<IndexCatalog?> Function()? catalog,
    Future<IndexValuation?> Function(String code, String? name)? code,
    Future<List<IndexCandidate>> Function(String)? search,
    Future<IndexValuation?> Function(IndexCandidate)? candidate,
    Future<IndexValuation?> Function(String)? symbol,
    Future<CsiPerfPoint?> Function(String)? pe,
    Future<CsiIndicator?> Function(String)? indicator,
    bool networkFail = false,
  }) =>
      IndexValuationPage(
        catalogLoader: catalog ?? () async => cat(),
        codeLoader: code ??
            (c, n) async {
              if (networkFail) throw Exception('网络错误');
              return c == '000922' ? zzh() : null;
            },
        searchLoader: search ?? (_) async => const [],
        candidateLoader: candidate ?? (c) async => null,
        symbolLoader: symbol ?? (s) async => s == 'SH000922' ? zzh() : null,
        peLoader: pe ??
            (c) async => CsiPerfPoint(
                date: '20260928', pe: c == '000300' ? 13.1 : 8.6),
        // 默认：中证官网也没有（除非某条用例自己注入）
        indicatorLoader: indicator ?? (c) async => null,
      );

  Future<void> tapAt(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Finder rowText(String label) => find.text(label);
  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  testWidgets('目录加载好：显示条数与「命中」数', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('查指数'), findsOneWidget); // 页面标题（内容也能单嵌进「指数看板」）
    expect(find.textContaining('共 4 条'), findsOneWidget);
    expect(find.textContaining('命中 4'), findsOneWidget);
    expect(find.text('中证红利'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点目录里的一条 → 出估值卡（股息率/PE/PB/ROE/分位）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('中证红利').first);

    expect(find.text('股息率'), findsOneWidget);
    expect(find.text('4.26%'), findsOneWidget); // 0.0426 → 4.26%（无 + 号）
    expect(find.text('8.61'), findsOneWidget);
    expect(find.text('0.85'), findsOneWidget);
    expect(find.text('9.86%'), findsOneWidget);
    expect(find.text('79.28%'), findsOneWidget);
    expect(find.text('高估'), findsOneWidget);
    expect(find.textContaining('分位窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索是本地过滤：输「红利」只剩两条，且命中数跟着变', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '红利');
    await tester.pumpAndSettle();

    expect(find.textContaining('命中 2'), findsOneWidget);
    expect(find.text('沪深300'), findsNothing);
    expect(find.text('中证红利'), findsWidgets);
    expect(find.text('300红利LV'), findsOneWidget);
  });

  testWidgets('按代码搜也认（000300）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '000300');
    await tester.pumpAndSettle();

    expect(find.textContaining('命中 1'), findsOneWidget);
    expect(find.text('沪深300'), findsOneWidget);
  });

  testWidgets('分类筛选：点「规模」只剩两条', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, chip('规模'));

    expect(find.textContaining('命中 2'), findsOneWidget);
    expect(find.text('中证红利'), findsNothing);
    await tapAt(tester, find.text('清空')); // 一键清掉所有条件
    expect(find.textContaining('命中 4'), findsOneWidget);
  });

  testWidgets('排序：切到「按月度收益」+ 倒序，正序倒序都可用', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, find.text('按代码'));
    await tester.pumpAndSettle();
    await tapAt(tester, find.text('按月度收益'));
    expect(find.text('按月度收益'), findsOneWidget);

    // 缺月度收益的那条（上证指数）永远沉底：倒序也不许冒到最前
    await tapAt(tester, find.byIcon(Icons.arrow_upward));
    final before = tester.getTopLeft(rowText('上证指数')).dy;
    final after1 = tester.getTopLeft(rowText('300红利LV')).dy;
    expect(before, greaterThan(after1)); // 有值的在上面
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
  });

  testWidgets('只看被基金跟踪的', (tester) async {
    await tester.pumpWidget(host(page(
      catalog: () async => IndexCatalog([
        item('000922', '中证红利', tracked: true),
        item('000001', '上证指数', series: '上证系列指数', tracked: false),
      ], DateTime(2026, 9, 29)),
    )));
    await tester.pumpAndSettle();

    await tapAt(tester, find.widgetWithText(FilterChip, '只看被基金跟踪的'));
    expect(find.text('上证指数'), findsNothing);
    expect(find.text('中证红利'), findsWidgets);
  });

  testWidgets('目录里没有 → 去东财联想兜底（国证/恒生这些目录外）', (tester) async {
    await tester.pumpWidget(host(page(
      search: (q) async => const [
        IndexCandidate(quoteId: '0.980080', code: '980080', name: '国证成长100'),
      ],
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '国证成长100');
    await tester.pump(const Duration(milliseconds: 400)); // 防抖 350ms
    await tester.pumpAndSettle();
    // 联想卡在列表里靠下：ListView 懒加载，不滚过去根本不会被构建
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();

    expect(find.text('联想结果'), findsOneWidget);
    expect(find.textContaining('东财联想'), findsOneWidget);
    expect(find.text('国证成长100'), findsWidgets);
  });

  testWidgets('本地有命中时**不**去打扰联想接口', (tester) async {
    var called = 0;
    await tester.pumpWidget(host(page(
      search: (q) async {
        called++;
        return const [];
      },
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '红利');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(called, 0);
    expect(find.text('联想结果'), findsNothing);
  });

  testWidgets('蛋卷没收录但中证官网有 → 出「中证官网」口径的卡（标清来源）', (tester) async {
    await tester.pumpWidget(host(page(
      indicator: (c) async => c == '000300'
          ? const CsiIndicator(
              date: '20260928',
              code: '000300',
              name: '沪深300',
              pe1: 13.42,
              pe2: 13.42,
              dp1: 2.72,
              dp2: 2.74,
            )
          : null,
    )));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('沪深300').first); // 蛋卷那条 loader 只认 000922

    expect(find.textContaining('中证官网 · 2026-09-28'), findsOneWidget);
    expect(find.text('2.74%'), findsOneWidget); // 股息率（计算用股本）
    expect(find.text('13.42'), findsWidgets); // 市盈率
    expect(find.textContaining('2.72%'), findsOneWidget); // 股息率（总股本）
    expect(find.textContaining('中证指数官网的官方指标'), findsOneWidget);
    // 不该再显示"查不到"
    expect(find.text('这个指数暂时查不到'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两个源都没有 → 才说"没有数据源"（并说明国证/恒生本就没有）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('300红利LV').first);

    expect(find.text('这个指数暂时查不到'), findsOneWidget);
    expect(find.textContaining('国证系'), findsOneWidget);
    expect(find.textContaining('不是"这个指数没有股息"'), findsOneWidget);
  });

  testWidgets('蛋卷没收录 → 如实说"暂时查不到"，并强调不是"没有股息"', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('沪深300').first); // codeLoader 只认 000922

    expect(find.text('这个指数暂时查不到'), findsOneWidget);
    expect(find.textContaining('不是"这个指数没有股息"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络失败 → 提示网络问题（与"没收录"分开说）', (tester) async {
    await tester.pumpWidget(host(page(networkFail: true)));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('中证红利').first);

    expect(find.text('这个指数暂时查不到'), findsOneWidget);
    expect(find.textContaining('网络出错'), findsOneWidget);
  });

  testWidgets('目录取数失败：如实说没取到，且不假装"指数只有这些"', (tester) async {
    await tester.pumpWidget(host(page(catalog: () async => null)));
    await tester.pumpAndSettle();

    expect(find.text('指数目录没取到'), findsOneWidget);
    expect(find.textContaining('不是"指数只有这些"'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('源返回的名字与目录不一致 → 两个名字都摆出来提醒', (tester) async {
    await tester.pumpWidget(host(page(
      code: (c, n) async => IndexValuation(
        symbol: 'SH000922',
        name: '中证红利全收益',
        pe: 8.6,
        yeild: 0.0426,
        date: '2026-09-28',
      ),
    )));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('300红利LV').first);

    expect(find.textContaining('你查的是「300红利LV」'), findsOneWidget);
    expect(find.textContaining('数据源返回的是「中证红利全收益」'), findsOneWidget);
  });

  testWidgets('估值缺字段时显示 --（不编 0），页面也不崩', (tester) async {
    await tester.pumpWidget(host(page(
      code: (c, n) async => IndexValuation(
        symbol: 'SH000300',
        name: '沪深300',
        pe: 13.1274,
        date: '2026-09-28',
      ),
    )));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('沪深300').first);

    expect(find.text('13.13'), findsOneWidget);
    expect(find.text('--'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 320dp + 字体 1.3：列表与筛选都不溢出', (tester) async {
    await tester.pumpWidget(host(page(), width: 320, scale: 1.3));
    await tester.pumpAndSettle();

    await tapAt(tester, rowText('中证红利').first);
    expect(find.text('4.26%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾选两个 → 底部出现「开始对比」→ 进对比表', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    // 勾第一个：只选一个时按钮不可用（对比至少要两个）
    await tapAt(tester, find.byType(Checkbox).first);
    expect(find.text('已选 1 个指数'), findsOneWidget);
    expect(find.text('再选一个'), findsOneWidget);

    await tapAt(tester, find.byType(Checkbox).at(1));
    expect(find.text('已选 2 个指数'), findsOneWidget);

    await tapAt(tester, find.text('开始对比'));
    expect(find.text('指数对比'), findsOneWidget);
    expect(find.text('对比 2 个指数'), findsOneWidget);
    expect(find.textContaining('有数的：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾错了能清空：底部「清空」把选择去掉', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    await tapAt(tester, find.byType(Checkbox).first);
    expect(find.text('已选 1 个指数'), findsOneWidget);
    await tapAt(tester, find.text('清空'));
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('列表超一页：先给一页，点「显示更多」再加一页', (tester) async {
    final many = IndexCatalog([
      for (var i = 0; i < kIndexListPage + 5; i++)
        item('9${i.toString().padLeft(5, '0')}', '测试指数$i'),
    ], DateTime(2026, 9, 29));
    await tester.pumpWidget(host(page(catalog: () async => many)));
    await tester.pumpAndSettle();

    expect(find.text('测试指数0'), findsOneWidget);
    expect(find.text('测试指数${kIndexListPage + 1}'), findsNothing);
    await tapAt(tester, find.textContaining('还有 5 条'));
    expect(find.text('测试指数${kIndexListPage + 4}'), findsOneWidget);
  });
}
