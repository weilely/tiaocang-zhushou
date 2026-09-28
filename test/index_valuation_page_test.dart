import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_eva.dart';
import 'package:invest_tracker/ui/index_valuation_page.dart';

/// 指数估值通用页：搜索 / 快捷 chips / 估值卡 / 查不到 / 网络失败
///
/// 三个 loader 全部注入（widget 测试里没有 Provider、没有网络）。
void main() {
  IndexValuation zzh() => IndexValuation(
        symbol: 'SH000922',
        name: '中证红利',
        pe: 8.6082,
        pb: 0.8485,
        yeild: 0.0426,
        roe: 0.0986,
        pePercentile: 0.7928,
        pbPercentile: 0.5032,
        windowStart: DateTime(2016, 6, 15), // 蛋卷给的 begin_at
        date: '2026-09-28',
        evaType: 'high',
      );

  Widget host(
    Widget child, {
    double width = 400,
    double scale = 1.0,
  }) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 880),
            textScaler: TextScaler.linear(scale),
          ),
          child: child,
        ),
      );

  /// 默认那一套 loader：常用清单里只有 SH000922 能查到，其余当"未收录"
  Widget page({
    Future<List<IndexCandidate>> Function(String)? search,
    Future<IndexValuation?> Function(String)? symbol,
    Future<IndexValuation?> Function(IndexCandidate)? candidate,
    bool networkFail = false,
  }) =>
      IndexValuationPage(
        searchLoader: search ?? (_) async => const [],
        symbolLoader: symbol ??
            (s) async {
              if (networkFail) throw Exception('网络错误');
              return s == 'SH000922' ? zzh() : null;
            },
        candidateLoader: candidate ??
            (c) async => c.code == '000922' ? zzh() : null,
      );

  /// 精确 finder：`find.text` 会把输入框里的文字也算进去，容易数错
  Finder chip(String label) => find.widgetWithText(ActionChip, label);
  Finder cand(String label) => find.widgetWithText(ListTile, label);

  /// 点之前先滚到可见：快捷区在测试视口（800x600）下面，直接 tap 会落空
  Future<void> tapAt(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('快捷 chips 点中证红利 → 出估值卡（股息率/PE/PB/ROE/分位）', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    expect(find.text('指数估值'), findsOneWidget);
    await tapAt(tester, chip('中证红利'));

    expect(find.text('股息率'), findsOneWidget);
    expect(find.text('4.26%'), findsOneWidget); // 0.0426 → 4.26%
    expect(find.text('8.61'), findsOneWidget); // PE
    expect(find.text('0.85'), findsOneWidget); // PB
    expect(find.text('9.86%'), findsOneWidget); // ROE
    expect(find.text('79.28%'), findsOneWidget); // PE 分位
    expect(find.text('高估'), findsOneWidget); // eva_type=high
    expect(find.textContaining('分位窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索 → 候选 → 点选 → 出估值卡（防抖后才会打接口）', (tester) async {
    await tester.pumpWidget(host(page(
      search: (q) async => const [
        IndexCandidate(quoteId: '1.000922', code: '000922', name: '中证红利'),
      ],
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '中证红利');
    // 防抖 350ms：不到点不该出候选行（输入框里的字不算 ListTile）
    await tester.pump(const Duration(milliseconds: 100));
    expect(cand('中证红利'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(cand('中证红利'), findsOneWidget); // 候选行了
    await tapAt(tester, cand('中证红利'));
    expect(find.text('4.26%'), findsOneWidget);
  });

  testWidgets('蛋卷没收录的指数 → 如实说"暂时查不到"，并强调不是"没有股息"', (tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();

    // 快捷清单里挑一个默认 loader 查不到的（红利低波）
    await tapAt(tester, chip('红利低波'));

    expect(find.text('这个指数暂时查不到'), findsOneWidget);
    expect(find.textContaining('红利低波'), findsWidgets);
    expect(find.textContaining('不是"这个指数没有股息"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络失败 → 提示网络问题（与"没收录"分开说）', (tester) async {
    await tester.pumpWidget(host(page(networkFail: true)));
    await tester.pumpAndSettle();
    await tapAt(tester, chip('中证红利'));

    expect(find.text('这个指数暂时查不到'), findsOneWidget);
    expect(find.textContaining('网络出错'), findsOneWidget);
  });

  testWidgets('窄屏 320dp + 字体 1.3：估值卡与快捷区都不溢出', (tester) async {
    await tester.pumpWidget(host(page(), width: 320, scale: 1.3));
    await tester.pumpAndSettle();
    await tapAt(tester, chip('中证红利'));
    expect(find.text('4.26%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('估值缺字段时显示 --（不编 0），页面也不崩', (tester) async {
    await tester.pumpWidget(host(page(
      symbol: (s) async => const IndexValuation(
        symbol: 'SH000300',
        name: '沪深300',
        pe: 13.1274,
        date: '2026-09-28',
      ),
    )));
    await tester.pumpAndSettle();
    await tapAt(tester, chip('沪深300'));

    expect(find.text('13.13'), findsOneWidget);
    expect(find.text('--'), findsWidgets); // 股息率/PB/ROE/分位都缺
    expect(tester.takeException(), isNull);
  });
}
