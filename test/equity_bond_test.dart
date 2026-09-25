import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/db.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/macro_allocation.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/rebalance_page.dart';
import 'package:provider/provider.dart';

/// 「股债平衡」开关 + 折算读数（2026-09-24 用户要求）
///
/// 口径（用户拍板）：开关在**设置页与调仓页两处**都能开关；设置页每行选「大类」；
/// **现金不纳入计划**（分母 = 持仓市值）；**只给建议**，不改用户填的目标、不写流水。
void main() {
  Asset fund(int id, String code, String name) =>
      Asset(id: id, code: code, name: name, kind: AssetKind.fund);

  Txn buy({required int accountId, required int assetId, required double amount}) =>
      Txn(
        accountId: accountId,
        assetId: assetId,
        type: TxnType.buy,
        date: DateTime(2026, 1, 5),
        amount: amount,
        shares: amount, // price = 1，市值直接等于金额
        price: 1,
      );

  Quote q(String code) => Quote(
        code: code,
        kind: AssetKind.fund,
        price: 1,
        prevClose: 1,
        priceType: 'nav',
        infoDate: '2026-09-24',
      );

  /// 账户 1 持有三只权益基金（10 : 60 : 30），另有现金 1 万（**不应进计划**）
  AppState build() {
    final st = AppState()..loading = false;
    st.accounts = [Account(id: 1, name: '易稳易增')];
    st.assetList = [
      fund(1, 'AAA', '甲基金'),
      fund(2, 'BBB', '乙基金'),
      fund(3, 'CCC', '丙基金'),
    ];
    st.assetsById = {for (final a in st.assetList) a.id!: a};
    st.quotes = {'AAA': q('AAA'), 'BBB': q('BBB'), 'CCC': q('CCC')};
    st.txns = [
      buy(accountId: 1, assetId: 1, amount: 10000),
      buy(accountId: 1, assetId: 2, amount: 60000),
      buy(accountId: 1, assetId: 3, amount: 30000),
    ];
    st.allTargets = [
      TargetAlloc(id: 1, accountId: 1, key: 'asset:AAA', label: '甲基金', ratio: 0.10),
      TargetAlloc(id: 2, accountId: 1, key: 'asset:BBB', label: '乙基金', ratio: 0.60),
      TargetAlloc(id: 3, accountId: 1, key: 'asset:CCC', label: '丙基金', ratio: 0.30),
    ];
    st.accountFilter = 1;
    // 利差分位样本：0.1 ~ 0.9 共 20 条（minSamples=20），当前值 0.5 → 分位 50%
    st.macroHistory = [
      for (var i = 1; i <= 20; i++)
        MacroRow(
          date: '2026-09-${i.toString().padLeft(2, '0')}',
          hs300Pe: 13,
          cn10y: 1.7,
          erp: i / 20,
        ),
    ];
    return st;
  }

  group('开关与折算读数', () {
    test('关着的时候没有任何建议（保持现状）', () {
      final st = build();
      expect(st.equityBondEnabledFor(1), isFalse);
      expect(st.equityBondAdvice, isNull);
      expect(st.equityBondTargetsFor(st.positions), isNull);
    });

    test('打开后：分位 100% → 权益目标封顶 80%，差额 = 该挪出的钱', () {
      final st = build()..equityBondOn.add(1);
      final a = st.equityBondAdvice;
      expect(a, isNotNull);
      // 样本里当前值就是最高的那条（erp=1.0）→ 分位 100%
      expect(a!.percentile, closeTo(1.0, 1e-9));
      // 100% 分位也不给满仓：上面那条 20%~80% 的截平生效
      expect(a.targetEquity, closeTo(0.80, 1e-9));
      expect(a.currentEquity, closeTo(1.0, 1e-9));
      // 分母是持仓市值 10 万（现金不进计划），需要从权益挪出 2 万
      expect(a.totalMarket, closeTo(100000, 1e-6));
      expect(a.amountToMove, closeTo(-20000, 1e-6));
      // 还没买债券 → 提示去标 / 去买
      expect(a.hint, isNotNull);
    });

    test('标了 021606 是债券但还没持仓 → 提示"记一笔买入就会进方案"', () {
      final st = build()..equityBondOn.add(1);
      st.assetClasses['021606'] = AssetClass.bond;
      expect(st.equityBondAdvice!.hint, contains('021606'));
      expect(st.equityBondAdvice!.hint, contains('还没有持仓'));
    });

    test('折算出的标的目标：权益池 80% 按 10:60:30 分给三只', () {
      final st = build()..equityBondOn.add(1);
      final conv = st.equityBondTargetsFor(st.positions)!;
      expect(conv.targets['AAA'], closeTo(0.08, 1e-9));
      expect(conv.targets['BBB'], closeTo(0.48, 1e-9));
      expect(conv.targets['CCC'], closeTo(0.24, 1e-9));
      expect(conv.equityWeight, closeTo(0.80, 1e-9));
    });

    test('「全部账户」视图没有归属：开关不可用、不给建议', () {
      final st = build()..equityBondOn.add(1);
      st.accountFilter = null;
      expect(st.equityBondEnabledFor(null), isFalse);
      expect(st.equityBondAdvice, isNull);
    });

    test('调仓方案的标的级目标跟着折算走（不动用户填的 targets）', () {
      final st = build();
      final before = st.rebalancePlan().lines
          .firstWhere((l) => l.target.code == 'BBB')
          .target
          .targetRatio;
      expect(before, closeTo(0.60, 1e-9));

      st.equityBondOn.add(1);
      final after = st.rebalancePlan().lines
          .firstWhere((l) => l.target.code == 'BBB')
          .target
          .targetRatio;
      expect(after, closeTo(0.48, 1e-9));
      // 用户填的还是 60%（只给建议，不偷偷改）
      expect(
        st.targetsOf(1).firstWhere((t) => t.key == 'asset:BBB').ratio,
        closeTo(0.60, 1e-9),
      );
    });
  });

  group('界面', () {
    Widget host(AppState st) => ChangeNotifierProvider<AppState>.value(
          value: st,
          child: const MaterialApp(home: Scaffold(body: RebalancePage())),
        );

    testWidgets('调仓页有开关（默认关）', (tester) async {
      final st = build();
      await tester.pumpWidget(host(st));
      await tester.pumpAndSettle();
      expect(find.text('股债平衡'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
      // 开关默认关着
      expect(st.equityBondEnabledFor(1), isFalse);
      // 不点它：开关会写 settings 表，而 widget 测试里没有 sqflite
      // （项目里凡是"点了就写库"的路径都不在 widget 测试里点，见 home_shell_test）
    });

    testWidgets('窄屏 320dp + 字体 1.3 倍：开着也不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final st = build()..equityBondOn.add(1);
      await tester.pumpWidget(MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: ChangeNotifierProvider<AppState>.value(
          value: st,
          child: const Scaffold(body: RebalancePage()),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
