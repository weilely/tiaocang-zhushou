import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/fund_detail.dart';
import 'package:invest_tracker/data/hithink_api.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/ui/fund_profile_page.dart';

/// 基金档案页的**版式与状态**
///
/// 用注入口 `loader` 喂假数据，所以不需要 sqflite/网络（widget 测试里都没有）。
/// 重点钉三件事：①真实字段能不能画出来 ②「没取到」与「没有数据」分不分得清
/// ③**用户手机是窄屏 + 字体放大**，这种组合下不许溢出。
void main() {
  FundDetailBundle fullBundle() => FundDetailBundle(
        profile: FundProfile(
          thscode: '021362.OF',
          ticker: '021362',
          name: '中证A',
          estabDate: DateTime(2024, 10, 29),
          companyName: '易方达基金管理有限公司',
          managerName: '李树建',
          scale: '261682632.55',
          unitNav: 1.6978,
          managers: [
            FundManager(
              id: '1',
              name: '李树建',
              tenureReturnPct: 69.78,
              tenureDays: 693,
              startDate: DateTime(2024, 10, 29),
            ),
          ],
          tradeRules: const [
            FundTradeRule(title: '买入提交', displayTime: '今日15点后'),
            FundTradeRule(title: '确认份额', displayTime: '09-24(星期四)'),
          ],
          rates: const [
            FundRate(
              type: 'purchase',
              chargeMode: 'front',
              condition: '100万元以下',
              standardRate: '1.20%',
              discountedRate: '0.12%',
            ),
            FundRate(
              type: 'management',
              chargeMode: 'ongoing',
              condition: '',
              standardRate: '0.50%',
            ),
          ],
        ),
        portfolio: FundPortfolio(
          stockRatioPct: 89.8,
          mainIndustry: '周期',
          concentrationRatio: 0.6109,
          holdings: [
            FundStockHolding(
              thscode: '601899.SH',
              ticker: '601899',
              name: '紫金矿业',
              holdRatio: 10.3,
              positionCapital: 74256018,
              rank: 1,
              publishDate: DateTime(2026, 7, 21),
            ),
          ],
        ),
        dividends: FundDividends(
          count: 2,
          total: '0.35元/份',
          items: [
            FundDividend(
              perTenBeforeTax: 0.5,
              perTenAfterTax: 0.45,
              progress: '实施',
              registrationDate: DateTime(2024, 1, 2),
              exDividendDate: DateTime(2024, 1, 3),
              paymentDate: DateTime(2024, 1, 4),
            ),
          ],
        ),
        fetchedAt: DateTime(2026, 9, 23, 10, 30),
      );

  /// 挂载一页；[scale] 是系统字体缩放（用户真机调成了「大」）
  ///
  /// [settle] 为 false 时只 pump 一帧 —— 加载态那张测试不能 settle
  /// （转圈动画永远不会停，`pumpAndSettle` 会一直等到超时）。
  Future<void> pumpPage(
    WidgetTester tester,
    Future<FundDetailBundle> Function(bool force) loader, {
    double scale = 1.0,
    Size size = const Size(400, 1600),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: FundProfilePage(
        code: '021362',
        name: '易方达黄金主题A',
        kind: AssetKind.fund,
        loader: loader,
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('三块数据都画出来：档案 / 经理 / 交易规则 / 费率 / 重仓股 / 分红', (tester) async {
    await pumpPage(tester, (_) async => fullBundle());

    expect(find.text('易方达黄金主题A'), findsOneWidget);
    expect(find.textContaining('021362 · 基金档案'), findsOneWidget);

    // 档案
    expect(find.text('易方达基金管理有限公司'), findsOneWidget);
    expect(find.text('2024-10-29'), findsOneWidget);
    expect(find.text('2.62亿'), findsOneWidget, reason: '9 位数字要紧凑显示');
    expect(find.text('1.6978'), findsOneWidget);

    // 经理：任职天数与回报
    expect(find.textContaining('李树建'), findsWidgets);
    expect(find.textContaining('任职 693 天'), findsOneWidget);
    expect(find.text('+69.78%'), findsOneWidget);

    // 交易规则与费率（费率是字符串，折后价带原价）
    expect(find.text('买入提交'), findsOneWidget);
    expect(find.text('今日15点后'), findsOneWidget);
    expect(find.text('0.12%（原 1.20%）'), findsOneWidget);
    expect(find.text('管理费'), findsOneWidget);
    expect(find.text('0.50%'), findsOneWidget);

    // 重仓股
    expect(find.textContaining('重仓股（2026-07-21）'), findsOneWidget);
    expect(find.text('紫金矿业'), findsOneWidget);
    expect(find.text('89.80%'), findsOneWidget);
    expect(find.text('周期'), findsOneWidget);
    expect(find.text('10.30%'), findsOneWidget);

    // 分红
    expect(find.text('分红记录（2 次）'), findsOneWidget);
    expect(find.textContaining('除息 2024-01-03'), findsOneWidget);
    expect(find.textContaining('每10份'), findsOneWidget);
    expect(find.textContaining('累计分红：0.35元/份'), findsOneWidget);

    // 来源说明
    expect(find.textContaining('数据来自同花顺'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认没分过红才说「没有分过红」，且不显示「累计分红 0.0」', (tester) async {
    await pumpPage(
      tester,
      (_) async => FundDetailBundle(
        profile: const FundProfile(
            thscode: '021362.OF', ticker: '021362', name: ''),
        dividends: const FundDividends(count: 0, total: '0.0'),
        fetchedAt: DateTime(2026, 9, 23),
      ),
    );

    expect(find.text('这只基金没有分过红'), findsOneWidget);
    expect(find.textContaining('累计分红'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分红接口挂了要说「没取到」，不能说成「没有分红」', (tester) async {
    await pumpPage(
      tester,
      (_) async => FundDetailBundle(
        profile: const FundProfile(
            thscode: '021362.OF', ticker: '021362', name: ''),
        dividendsError: '同花顺 code=4001 限流',
        fetchedAt: DateTime(2026, 9, 23),
      ),
    );

    expect(find.textContaining('没取到分红数据：同花顺 code=4001 限流'), findsOneWidget);
    expect(find.text('这只基金没有分过红'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没配 API Key：说清去哪配、给重试按钮，而不是一个空页面', (tester) async {
    await pumpPage(tester, (_) async {
      throw HithinkException('未配置同花顺 API Key（设置 → 同花顺数据源）');
    });

    expect(find.text('还没配置同花顺 API Key'), findsOneWidget);
    expect(find.textContaining('设置 → 同花顺数据源'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载中显示进度提示（不是一片空白）', (tester) async {
    final gate = Completer<FundDetailBundle>();
    await pumpPage(tester, (_) => gate.future,
        size: const Size(400, 800), settle: false);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    gate.complete(fullBundle());
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('窄屏 + 字体放大 1.3 倍：整页不溢出', (tester) async {
    await pumpPage(
      tester,
      (_) async => fullBundle(),
      scale: 1.3,
      // 真机是窄屏（≈360dp），这里再压到 320 留余量
      size: const Size(320, 1800),
    );

    expect(tester.takeException(), isNull,
        reason: '字体放大 + 窄屏下任何 RenderFlex overflow 都算失败');
    expect(find.textContaining('数据来自同花顺'), findsOneWidget);
  });
}
