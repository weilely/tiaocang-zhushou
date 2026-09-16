import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/cash_flow.dart';
import 'package:invest_tracker/logic/portfolio.dart';
import 'package:invest_tracker/logic/range_preset.dart';
import 'package:invest_tracker/logic/returns_calendar.dart';

/// 资金流清单：两条独立恒等式必须同时成立
///
/// ```
/// ① 期末资产 = 期初资产 + 净流入 + 账户盈亏
/// ② 账户盈亏 = Δ持仓市值 − 投入金额 + 赎回金额
///              + 现金分红 + 现金生息 + 现金调整
/// ```
void main() {
  final a1 = Asset(id: 1, code: '025497', name: '基金A', kind: AssetKind.fund);
  final a2 = Asset(id: 2, code: '510300', name: 'ETF-B', kind: AssetKind.etf);

  NavPoint nav(String code, String date, double v) =>
      NavPoint(code: code, date: date, nav: v, accNav: v);

  Txn txn({
    required int assetId,
    required TxnType type,
    required String date,
    double amount = 0,
    double shares = 0,
    double fee = 0,
  }) =>
      Txn(
        accountId: 1,
        assetId: assetId,
        type: type,
        date: DateTime.parse(date),
        amount: amount,
        shares: shares,
        price: shares > 0 ? amount / shares : 0,
        fee: fee,
      );

  CashTxn cash({
    required String type,
    required String date,
    required double amount,
    int accountId = 1,
  }) =>
      CashTxn(
        accountId: accountId,
        type: type,
        amount: amount,
        date: DateTime.parse(date),
      );

  DateRange range(String s, String e) =>
      DateRange(DateTime.parse(s), DateTime.parse(e));

  /// 一套「正常」数据：充值 → 买入 → 卖出一部分 → 分红 → 生息 → 提现
  ({
    List<AssetSeries> assets,
    List<Txn> txns,
    List<CashTxn> cashTxns,
  }) fixture() {
    final assets = [
      AssetSeries(asset: a1, navs: [
        nav(a1.code, '2026-08-28', 1.00),
        nav(a1.code, '2026-09-01', 1.10),
        nav(a1.code, '2026-09-05', 1.20),
        nav(a1.code, '2026-09-20', 1.05),
        nav(a1.code, '2026-09-30', 1.15),
      ]),
      AssetSeries(asset: a2, navs: [
        nav(a2.code, '2026-08-28', 2.00),
        nav(a2.code, '2026-09-01', 2.10),
        nav(a2.code, '2026-09-05', 1.90),
        nav(a2.code, '2026-09-20', 2.05),
        nav(a2.code, '2026-09-30', 2.20),
      ]),
    ];

    final txns = [
      // 期初（9 月之前）已持有，用于验证期初资产
      txn(assetId: 1, type: TxnType.buy, date: '2026-08-10',
          amount: 10000, shares: 10000),
      // 期初分红（与下面的现金流水成对，保证现⾦账本与交易一致）
      txn(assetId: 1, type: TxnType.dividend, date: '2026-08-20', amount: 300),
      // 期间买入
      txn(assetId: 2, type: TxnType.buy, date: '2026-09-02',
          amount: 5000, shares: 2500, fee: 5),
      // 期间卖出一部分
      txn(assetId: 1, type: TxnType.sell, date: '2026-09-10',
          amount: 2400, shares: 2000, fee: 2),
      // 期间分红
      txn(assetId: 2, type: TxnType.dividend, date: '2026-09-15', amount: 88),
    ];

    // 现金账本必须与交易成对（App 里由 saveTxnWithCash 保证）：
    // 每一笔买入/卖出/分红都有一条对应的现金流水，外加充值/提现/生息/调整。
    final cashTxns = [
      cash(type: CashType.deposit, date: '2026-08-05', amount: 20000),
      cash(type: CashType.invest, date: '2026-08-10', amount: -10000),
      cash(type: CashType.dividend, date: '2026-08-20', amount: 300),
      cash(type: CashType.deposit, date: '2026-09-01', amount: 12000),
      cash(type: CashType.invest, date: '2026-09-02', amount: -(5000.0 + 5)),
      cash(type: CashType.redeem, date: '2026-09-10', amount: 2400 - 2),
      cash(type: CashType.dividend, date: '2026-09-15', amount: 88),
      cash(type: CashType.income, date: '2026-09-18', amount: 12.5),
      cash(type: CashType.adjust, date: '2026-09-19', amount: -3.5),
      cash(type: CashType.withdraw, date: '2026-09-25', amount: -2000),
    ];

    return (assets: assets, txns: txns, cashTxns: cashTxns);
  }

  group('恒等式①：期末资产 = 期初资产 + 净流入 + 账户盈亏', () {
    test('整月区间严格成立', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );

      expect(s.identityGap.abs(), lessThan(1e-9),
          reason: '残差必须为 0，实际 ${s.identityGap}');
      expect(s.endAssets,
          closeTo(s.beginAssets + s.netFlow + s.pnl, 1e-9));
    });

    test('多组区间都成立（月初/月中/单日/跨月）', () {
      final f = fixture();
      for (final r in [
        range('2026-09-01', '2026-09-30'),
        range('2026-09-02', '2026-09-20'),
        range('2026-09-05', '2026-09-05'),
        range('2026-08-01', '2026-10-15'),
        range('2025-01-01', '2026-12-31'),
      ]) {
        final s = buildCashFlowStatement(
          assets: f.assets,
          txns: f.txns,
          cashTxns: f.cashTxns,
          range: r,
        );
        expect(s.identityGap.abs(), lessThan(1e-9),
            reason: '区间 $r 的残差为 ${s.identityGap}');
      }
    });

    test('数据里没有现金流水时也成立', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: const [],
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.identityGap.abs(), lessThan(1e-9));
      expect(s.beginCash, 0);
      expect(s.endCash, 0);
    });
  });

  group('恒等式②：账户盈亏 = Δ持仓市值 − 投入 + 赎回 + 分红 + 生息 + 调整', () {
    test('与残差口径一致（正常数据、无超卖）', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.pnl, closeTo(s.pnlCrossCheck, 1e-6),
          reason: '两条独立算式必须给出同一个数：'
              '残差 ${s.pnl} vs 复算 ${s.pnlCrossCheck}');
    });

    test('多组区间都一致', () {
      final f = fixture();
      for (final r in [
        range('2026-09-01', '2026-09-30'),
        range('2026-09-02', '2026-09-20'),
        range('2026-09-05', '2026-09-05'),
        range('2026-08-01', '2026-10-15'),
        range('2025-01-01', '2026-12-31'),
      ]) {
        final s = buildCashFlowStatement(
          assets: f.assets,
          txns: f.txns,
          cashTxns: f.cashTxns,
          range: r,
        );
        expect(s.pnl, closeTo(s.pnlCrossCheck, 1e-6),
            reason: '区间 $r：残差 ${s.pnl} vs 复算 ${s.pnlCrossCheck}');
      }
    });

    test('全区间账户盈亏 = 持仓累计收益 + 现金生息 + 现金调整', () {
      final f = fixture();
      // 建账首日 = 第一条现金流水（充值）
      final r = resolvePreset(
        RangePreset.all,
        now: DateTime(2026, 9, 30),
        earliest: DateTime(2026, 8, 5),
      )!;
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: r,
      );

      final positions = buildPositions(
        txns: f.txns,
        assets: {1: a1, 2: a2},
        quotes: {
          a1.code: Quote(code: a1.code, kind: AssetKind.fund, price: 1.15),
          a2.code: Quote(code: a2.code, kind: AssetKind.etf, price: 2.20),
        },
      );
      final summary = summarize(positions);

      // 全区间下，账户盈亏 = 持仓的累计收益 + 现金生息 + 现金调整
      // （分红已经计入持仓的已实现收益，所以这里不再重复加）
      expect(
        s.pnl,
        closeTo(summary.cumulativePnl + s.cashIncome + s.cashAdjust, 1e-6),
      );
      expect(s.beginAssets, closeTo(0, 1e-9));
      expect(s.identityGap.abs(), lessThan(1e-9));
    });
  });

  group('各项口径', () {
    test('投入金额含手续费、赎回金额为卖出净额', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.investAmount, closeTo(5005, 1e-9), reason: '5000 + 5 手续费');
      expect(s.redeemAmount, closeTo(2398, 1e-9), reason: '2400 − 2 手续费');
      expect(s.dividend, closeTo(88, 1e-9));
    });

    test('净流入 = 充值 − 提现；为负时标签变「净流出」', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.deposit, closeTo(12000, 1e-9));
      expect(s.withdraw, closeTo(2000, 1e-9), reason: '提现以负数入账，这里取绝对值');
      expect(s.netFlow, closeTo(10000, 1e-9));
      expect(s.netFlowLabel, '净流入');
      expect(s.isOutflow, isFalse);

      // 只留提现的区间 → 净流出
      final out = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-25', '2026-09-30'),
      );
      expect(out.netFlow, closeTo(-2000, 1e-9));
      expect(out.netFlowLabel, '净流出');
      expect(out.isOutflow, isTrue);
    });

    test('现金生息与现金调整单独统计', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.cashIncome, closeTo(12.5, 1e-9));
      expect(s.cashAdjust, closeTo(-3.5, 1e-9));
    });

    test('期初资产 = 期初持仓市值 + 期初现金余额', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      // 期初持仓：8/28 净值 1.00 × 10000 份 = 10000
      expect(s.beginHolding, closeTo(10000, 1e-9));
      // 期初现金：充值 20000 − 买入 10000 + 分红 300 = 10300
      expect(s.beginCash, closeTo(10300, 1e-9));
      expect(s.beginAssets, closeTo(20300, 1e-9));
    });

    test('期末资产 = 期末持仓市值 + 期末现金余额', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      // 期末持仓：基金 8000 份 × 1.15 = 9200；ETF 2500 份 × 2.20 = 5500
      expect(s.endHolding, closeTo(9200 + 5500, 1e-9));
      // 期末现金 = 全部现金流水之和
      final sum = f.cashTxns.fold<double>(0, (x, c) => x + c.amount);
      expect(s.endCash, closeTo(sum, 1e-9));
      expect(s.endAssets, closeTo(s.endHolding + s.endCash, 1e-9));
    });

    test('账户过滤只算该账户', () {
      final f = fixture();
      final other = [
        ...f.cashTxns,
        cash(type: CashType.deposit, date: '2026-09-03',
            amount: 9999, accountId: 2),
      ];
      final s1 = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: other,
        accountId: 1,
        range: range('2026-09-01', '2026-09-30'),
      );
      final sAll = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: other,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s1.deposit, closeTo(12000, 1e-9));
      expect(sAll.deposit, closeTo(12000 + 9999, 1e-9));
      expect(s1.identityGap.abs(), lessThan(1e-9));
    });
  });

  group('边界与空数据', () {
    test('「全部」区间期初资产为 0', () {
      final f = fixture();
      // 建账首日 = 第一条现金流水
      final earliest = DateTime(2026, 8, 5);
      final r = resolvePreset(
        RangePreset.all,
        now: DateTime(2026, 9, 30),
        earliest: earliest,
      )!;
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: r,
      );
      expect(s.beginHolding, closeTo(0, 1e-9));
      expect(s.beginCash, closeTo(0, 1e-9),
          reason: '全部区间的左端就是建账首日，之前不该有现金');
      expect(s.beginAssets, closeTo(0, 1e-9));
      expect(s.identityGap.abs(), lessThan(1e-9));
    });

    test('空数据：六项全 0 且不抛', () {
      final s = buildCashFlowStatement(
        assets: const [],
        txns: const [],
        cashTxns: const [],
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.beginAssets, 0);
      expect(s.endAssets, 0);
      expect(s.pnl, 0);
      expect(s.isEmpty, isTrue);
      expect(s.identityGap.abs(), lessThan(1e-9));
    });

    test('期初没有净值的持仓退回成本单价估值并标记', () {
      final noNav = Asset(id: 3, code: '999999', name: '无净值', kind: AssetKind.fund);
      final s = buildCashFlowStatement(
        assets: [AssetSeries(asset: noNav, navs: const [])],
        txns: [
          txn(assetId: 3, type: TxnType.buy, date: '2026-09-02',
              amount: 800, shares: 800),
        ],
        cashTxns: [cash(type: CashType.deposit, date: '2026-09-01', amount: 800)],
        range: range('2026-09-05', '2026-09-30'),
      );
      expect(s.beginHolding, closeTo(800, 1e-9), reason: '退回成本单价');
      expect(s.beginMissingNav, ['999999']);
      expect(s.endMissingNav, ['999999']);
      expect(s.identityGap.abs(), lessThan(1e-9));
    });

    test('期末现金为负时照实出数（回补历史流水的常见情况）', () {
      final s = buildCashFlowStatement(
        assets: [
          AssetSeries(asset: a1, navs: [nav(a1.code, '2026-09-10', 1.00)]),
        ],
        txns: [
          txn(assetId: 1, type: TxnType.buy, date: '2026-09-05',
              amount: 5000, shares: 5000),
        ],
        // 只补了交易，没补充值 → 现金为负
        cashTxns: [
          cash(type: CashType.invest, date: '2026-09-05', amount: -5000),
        ],
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.endCash, closeTo(-5000, 1e-9));
      expect(s.identityGap.abs(), lessThan(1e-9));
    });

    test('区间天数含首含尾；起始前一日用于期初估值', () {
      final r = range('2026-09-01', '2026-09-30');
      expect(r.days, 30);
      expect(r.dayBeforeStart, DateTime(2026, 8, 31));
      expect(range('2026-09-01', '2026-09-01').days, 1);
    });
  });

  group('现金流水不完整的自检', () {
    test('正常数据（买入都有扣款）不报不完整', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: f.cashTxns,
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.cashInvest, closeTo(5005, 1e-9));
      expect(s.cashRedeem, closeTo(2398, 1e-9));
      expect(s.investGap.abs(), lessThan(0.01));
      expect(s.ledgerIncomplete, isFalse);
    });

    test('只有交易、没有现金流水 → 报不完整，且账户盈亏会偏大', () {
      final f = fixture();
      final s = buildCashFlowStatement(
        assets: f.assets,
        txns: f.txns,
        cashTxns: const [],
        range: range('2026-09-01', '2026-09-30'),
      );
      expect(s.ledgerIncomplete, isTrue);
      expect(s.investGap, closeTo(5005, 1e-9));
      expect(s.redeemGap, closeTo(2398, 1e-9));
      // 恒等式① 仍然成立（它只是算术），但口径② 会给出更小的、经济上正确的数
      expect(s.identityGap.abs(), lessThan(1e-9));
      expect(s.pnl.abs(), greaterThan(s.pnlCrossCheck.abs()),
          reason: '没记支出的买入会被当成收益，账户盈亏偏大');
    });
  });

  group('交易联动生成的现金流水（买卖定投分红都走这里）', () {
    CashTxn? linked(TxnType type, {double amount = 0, double fee = 0}) =>
        linkedCashTxnFor(
          Txn(
            accountId: 7,
            assetId: 3,
            type: type,
            date: DateTime(2026, 9, 11),
            amount: amount,
            fee: fee,
          ),
          42,
        );

    test('买入：扣款 = −(成交金额 + 手续费)，类型 invest', () {
      final c = linked(TxnType.buy, amount: 5000, fee: 5)!;
      expect(c.type, CashType.invest);
      expect(c.amount, closeTo(-5005, 1e-9));
      expect(c.accountId, 7);
      expect(c.date, DateTime(2026, 9, 11));
      expect(c.srcTxnId, 42, reason: '要能指回原交易，现金页据此禁止删除');
      expect(c.note, '来自买入');
    });

    test('卖出：入账 = 成交金额 − 手续费，类型 redeem', () {
      final c = linked(TxnType.sell, amount: 2400, fee: 2)!;
      expect(c.type, CashType.redeem);
      expect(c.amount, closeTo(2398, 1e-9));
      expect(c.note, '来自卖出');
    });

    test('分红：入账 = 成交金额，类型 dividend', () {
      final c = linked(TxnType.dividend, amount: 88)!;
      expect(c.type, CashType.dividend);
      expect(c.amount, closeTo(88, 1e-9));
      expect(c.note, '来自分红');
    });

    test('金额为 0 时不写流水（不留一条没意义的 0）', () {
      expect(linked(TxnType.buy, amount: 0, fee: 0), isNull);
      expect(linked(TxnType.sell, amount: 0), isNull);
      expect(linked(TxnType.dividend, amount: 0), isNull);
      // 手续费与金额相互抵消时也是 0
      expect(linked(TxnType.sell, amount: 3, fee: 3), isNull);
    });

    test('与 Txn.netCash 符号一致（否则余额会和持仓对不上）', () {
      for (final t in [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 9, 1),
            amount: 1234.56,
            fee: 1.23),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.sell,
            date: DateTime(2026, 9, 2),
            amount: 2345.67,
            fee: 2.34),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.dividend,
            date: DateTime(2026, 9, 3),
            amount: 345.67),
      ]) {
        final c = linkedCashTxnFor(t, 1)!;
        expect(c.amount, closeTo(t.netCash, 1e-9),
            reason: '${t.type.name}：联动流水应与 Txn.netCash 完全一致');
      }
    });
  });
}
