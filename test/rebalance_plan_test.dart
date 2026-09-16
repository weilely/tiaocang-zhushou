import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/rebalance_plan.dart';

/// 调仓方案的口径。设计稿 `pic/111.jpg` 上的那张卡被整张搬进了测试里：
/// 预估 31043.31 / 目标 32923.16 / 调仓份额 1065.86 / 偏离 +6.06%。
void main() {
  group('设计稿那张卡能算通', () {
    // 用 nav=1 让「预估市值」直接等于份额，好把设计稿的金额原样搬进来
    final a = PlanTarget(
      code: '021362',
      name: '易方达黄金股指数发起式A',
      kind: AssetKind.fund,
      shares: 31043.31 / 1.7637, // 预估 = 31043.31
      nav: 1.7637,
      baseNav: 1.7637,
      targetRatio: 0.10,
      hasTarget: true,
    );
    final b = PlanTarget(
      code: 'X',
      name: '凑数',
      kind: AssetKind.etf,
      shares: 288188.26,
      nav: 1, // 预估 = 288188.26 → Σ预估 = 319231.57
      targetRatio: 0.9,
      hasTarget: true,
    );
    final plan = buildRebalancePlan(
      targets: [a, b],
      extraAmount: 10000,
      threshold: 0.05,
    );
    final line = plan.lines.firstWhere((l) => l.target.code == '021362');

    test('调仓基金市值 319,231.57 / 调仓总金额 329,231.57', () {
      expect(plan.estTotal, closeTo(319231.57, 0.05));
      expect(plan.total, closeTo(329231.57, 0.05));
    });

    test('预估 31,043.31 · 目标 32,923.16 · 差额 1,879.85', () {
      expect(line.est, closeTo(31043.31, 0.02));
      expect(line.targetValue, closeTo(32923.16, 0.02));
      expect(line.diff, closeTo(1879.85, 0.02));
    });

    test('调仓份额 1,065.86（差额 ÷ 预估净值）', () {
      expect(line.planShares, closeTo(1065.86, 0.02));
    });

    test('偏离 +6.06% 超过 5% 阈值 → 顶上那条告警会出来', () {
      expect(line.devPct, closeTo(6.06, 0.02));
      expect(line.exceeded, isTrue);
      expect(plan.anyExceeded, isTrue);
      expect(plan.buyCount, 2);
      expect(plan.sellCount, 0);
    });

    test('进度条 = 该标的预估市值 ÷ 全部预估市值', () {
      expect(line.weight, closeTo(31043.31 / 319231.57, 1e-9));
    });
  });

  group('公式与边界', () {
    test('追加金额按目标比例分下去（不是按现有市值摊）', () {
      final plan = buildRebalancePlan(
        targets: [
          PlanTarget(
              code: 'A',
              name: 'A',
              kind: AssetKind.fund,
              shares: 600,
              nav: 1,
              targetRatio: 0.6,
              hasTarget: true),
          PlanTarget(
              code: 'B',
              name: 'B',
              kind: AssetKind.fund,
              shares: 400,
              nav: 1,
              targetRatio: 0.4,
              hasTarget: true),
        ],
        extraAmount: 1000,
      );
      // 总金额 2000 → 目标 1200 / 800
      expect(plan.estTotal, 1000);
      expect(plan.total, 2000);
      expect(plan.lines.firstWhere((l) => l.target.code == 'A').targetValue, 1200);
      expect(plan.lines.firstWhere((l) => l.target.code == 'B').targetValue, 800);
      expect(plan.lines.firstWhere((l) => l.target.code == 'A').diff, 600);
      expect(plan.lines.firstWhere((l) => l.target.code == 'B').diff, 400);
      expect(plan.buyCount, 2);
    });

    test('超配的标的给的是卖出，差额为负', () {
      final plan = buildRebalancePlan(
        targets: [
          PlanTarget(
              code: 'A',
              name: 'A',
              kind: AssetKind.fund,
              shares: 800,
              nav: 1,
              targetRatio: 0.5,
              hasTarget: true),
          PlanTarget(
              code: 'B',
              name: 'B',
              kind: AssetKind.fund,
              shares: 200,
              nav: 1,
              targetRatio: 0.5,
              hasTarget: true),
        ],
        extraAmount: 0,
      );
      final a = plan.lines.firstWhere((l) => l.target.code == 'A');
      expect(a.diff, -300);
      expect(a.isBuy, isFalse);
      expect(a.planShares, -300);
      expect(plan.sellCount, 1);
      expect(plan.buyCount, 1);
    });

    test('未设目标：目标=预估、不动作、不计入目标合计', () {
      final plan = buildRebalancePlan(
        targets: [
          PlanTarget(
              code: 'A',
              name: 'A',
              kind: AssetKind.fund,
              shares: 100,
              nav: 1,
              targetRatio: 0,
              hasTarget: false),
        ],
        extraAmount: 500,
      );
      final a = plan.lines.single;
      expect(a.targetValue, a.est);
      expect(a.diff, 0);
      expect(a.hasAction, isFalse);
      expect(a.exceeded, isFalse);
      expect(plan.unsetCount, 1);
      expect(plan.targetSum, 0);
      // 进度条仍按占比画
      expect(a.weight, 1);
    });

    test('没有净值的标的：预估 0、份额 0，不炸', () {
      final plan = buildRebalancePlan(
        targets: [
          PlanTarget(
              code: 'A',
              name: 'A',
              kind: AssetKind.fund,
              shares: 100,
              nav: null,
              targetRatio: 0.5,
              hasTarget: true),
        ],
        extraAmount: 0,
      );
      final a = plan.lines.single;
      expect(a.est, 0);
      expect(a.planShares, 0);
      expect(a.devPct, 0);
      expect(a.weight, 0);
    });

    test('份额取整：基金 2 位小数，场内取整，卖出保留符号', () {
      expect(roundPlanShares(1065.8549, AssetKind.fund), 1065.85);
      expect(roundPlanShares(1065.8552, AssetKind.fund), 1065.86);
      expect(roundPlanShares(2196.7, AssetKind.etf), 2197);
      expect(roundPlanShares(-300.6, AssetKind.etf), -301);
      expect(roundPlanShares(-1065.8552, AssetKind.fund), -1065.86);
      expect(roundPlanShares(0, AssetKind.fund), 0);
    });
  });

  group('场外基金的当日预估涨幅', () {
    test('关联 ETF 的涨幅直接就是预估涨幅（不折算）', () {
      expect(
        fundEstimatePct(navPublishedToday: false, linkChangePct: 2),
        2,
      );
      expect(
        fundEstimatePct(navPublishedToday: false, linkChangePct: -1.2),
        -1.2,
      );
    });

    test('折算比例做成常量：想按 95% 仓位折算改一个数就够', () {
      expect(
        fundEstimatePct(navPublishedToday: false, linkChangePct: 2, factor: 0.95),
        closeTo(1.9, 1e-9),
      );
    });

    test('今日净值已公布 → 0（当天结束，不再叠估计）', () {
      expect(fundEstimatePct(navPublishedToday: true, linkChangePct: 2), 0);
    });

    test('没有关联 ETF 的涨幅 → 0', () {
      expect(fundEstimatePct(navPublishedToday: false), 0);
      expect(fundEstimatePct(navPublishedToday: false, linkChangePct: double.nan), 0);
    });
  });

  group('预估净值', () {
    test('场外 = 最新净值 × (1 + 涨幅)', () {
      expect(
        planNavFor(kind: AssetKind.fund, baseNav: 1.7637, pct: 2),
        closeTo(1.7637 * 1.02, 1e-9),
      );
    });

    test('场内 = 实时价；没有实时价退回最新净值', () {
      expect(
        planNavFor(
            kind: AssetKind.etf, baseNav: 4.5489, pct: -0.59, realtimePrice: 4.552),
        4.552,
      );
      expect(
        planNavFor(kind: AssetKind.etf, baseNav: 4.5489, pct: 0),
        4.5489,
      );
    });

    test('场外没有历史净值就没有预估净值', () {
      expect(planNavFor(kind: AssetKind.fund, baseNav: null, pct: 1), isNull);
    });
  });

  // ---------------- 当日取值口径（有净值就不要写"预估"） ----------------

  group('resolveFundQuote：今天净值已公布 vs 还在估', () {
    test('净值已公布 → 用真实净值与真实涨幅，手改的值不生效', () {
      final q = resolveFundQuote(
        baseNav: 1.7209,
        baseChangePct: -1.93,
        navPublishedToday: true,
        linkChangePct: -2.19,
        overridePct: 9.9,
      );
      expect(q.actual, isTrue);
      expect(q.nav, closeTo(1.7209, 1e-9), reason: '直接用当日净值，不再×(1+涨幅)');
      expect(q.pct, closeTo(-1.93, 1e-9), reason: '真实涨幅来自库里那条净值');
    });

    test('净值没公布 → 用关联 ETF 涨幅估，actual=false', () {
      final q = resolveFundQuote(
        baseNav: 1.7209,
        baseChangePct: -1.20,
        navPublishedToday: false,
        linkChangePct: -2.19,
      );
      expect(q.actual, isFalse);
      expect(q.pct, closeTo(-2.19, 1e-9));
      expect(q.nav, closeTo(1.7209 * (1 - 0.0219), 1e-9));
    });

    test('没公布时手改优先，其次基金自己的盘中估值', () {
      final edited = resolveFundQuote(
        baseNav: 2.0,
        baseChangePct: 0,
        navPublishedToday: false,
        linkChangePct: -2.19,
        overridePct: 1.5,
      );
      expect(edited.pct, closeTo(1.5, 1e-9));
      expect(edited.nav, closeTo(2.0 * 1.015, 1e-9));
      expect(edited.actual, isFalse);

      final own = resolveFundQuote(
        baseNav: 2.0,
        baseChangePct: 0,
        navPublishedToday: false,
        ownEstPct: 0.8,
      );
      expect(own.pct, closeTo(0.8, 1e-9));
    });

    test('没有基准净值时 nav 为 null（卡片显示 --），actual 仍标明真实/估算', () {
      final q = resolveFundQuote(
        baseNav: null,
        baseChangePct: 1.1,
        navPublishedToday: true,
      );
      expect(q.nav, isNull);
      expect(q.actual, isTrue);
      expect(q.pct, closeTo(1.1, 1e-9));
    });
  });
}