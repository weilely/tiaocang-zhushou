import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/state/app_state.dart';

/// 调仓目标按账户分开（v8 起）
///
/// 用户要求：「把调仓和设置页面的调仓目标资产与账户关联起来，切换账户时也一同
/// 切换，互不相干」。这里盯住三件事：
/// 1. 每个账户各拿各的目标（切账户就换一套）；
/// 2. 「全部账户」是**按市值加权合并**后的视图（比例由「占本账户」折算成
///    「占所有账户」），且这个视图**不能写库**；
/// 3. 老备份（没有 account_id）读进来要有归属，不能变成谁也看不见的目标。
void main() {
  Asset asset(int id, String code, String name) =>
      Asset(id: id, code: code, name: name, kind: AssetKind.etf);

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
        kind: AssetKind.etf,
        // 场内：预估净值就是实时价，用 price=1 让市值 = 份额 = 投入金额
        price: 1,
        prevClose: 1,
        priceType: 'price',
        infoDate: '2026-01-05',
      );

  /// 账户 1 持有 A（市值 1000），账户 2 持有 A（3000）与 B（1000）
  AppState build() {
    final st = AppState()..loading = false;
    st.accounts = [
      Account(id: 1, name: '易稳易增'),
      Account(id: 2, name: '天天基金'),
    ];
    st.assetList = [asset(1, 'AAA', '甲基金'), asset(2, 'BBB', '乙基金')];
    st.assetsById = {for (final a in st.assetList) a.id!: a};
    st.quotes = {'AAA': q('AAA'), 'BBB': q('BBB')};
    st.txns = [
      buy(accountId: 1, assetId: 1, amount: 1000),
      buy(accountId: 2, assetId: 1, amount: 3000),
      buy(accountId: 2, assetId: 2, amount: 1000),
    ];
    return st;
  }

  group('按账户各拿各的', () {
    test('切账户换一整套目标，互不相干', () {
      final st = build();
      st.allTargets = [
        TargetAlloc(id: 1, accountId: 1, key: 'asset:AAA', label: '甲基金', ratio: 0.6),
        TargetAlloc(id: 2, accountId: 2, key: 'asset:BBB', label: '乙基金', ratio: 0.5),
      ];

      st.accountFilter = 1;
      expect(st.targets.map((t) => t.key), ['asset:AAA']);

      st.accountFilter = 2;
      expect(st.targets.map((t) => t.key), ['asset:BBB']);

      // 同一只标的在两个账户各有各的比例
      st.allTargets.add(
          TargetAlloc(id: 3, accountId: 2, key: 'asset:AAA', label: '甲基金', ratio: 0.2));
      st.accountFilter = 1;
      expect(st.targets.single.ratio, closeTo(0.6, 1e-9));
      st.accountFilter = 2;
      expect(
        st.targets.firstWhere((t) => t.key == 'asset:AAA').ratio,
        closeTo(0.2, 1e-9),
      );
    });

    test('「调仓方案」跟着账户走：账户 1 只算账户 1 的持仓', () {
      final st = build();
      st.allTargets = [
        TargetAlloc(id: 1, accountId: 1, key: 'asset:AAA', label: '甲基金', ratio: 1),
      ];
      st.accountFilter = 1;
      final plan = st.rebalancePlan();
      expect(plan.lines.map((l) => l.target.code), ['AAA']);
      expect(plan.estTotal, closeTo(1000, 0.01));

      st.accountFilter = 2;
      final plan2 = st.rebalancePlan();
      // 账户 2 有两只标的，且目标里只给它设过 BBB
      expect(plan2.lines.map((l) => l.target.code).toSet(), {'AAA', 'BBB'});
      expect(plan2.estTotal, closeTo(4000, 0.01));
    });
  });

  group('「全部账户」是加权合并的只读视图', () {
    test('比例按各账户市值加权：0.6×1000/5000 + 0.2×4000/5000 = 0.28', () {
      final st = build();
      st.allTargets = [
        TargetAlloc(id: 1, accountId: 1, key: 'asset:AAA', label: '甲基金', ratio: 0.6),
        TargetAlloc(id: 2, accountId: 2, key: 'asset:AAA', label: '甲基金', ratio: 0.2),
      ];
      st.accountFilter = null;
      final merged = st.targets.single;
      // 账户 1 市值 1000、账户 2 市值 4000（AAA 3000 + BBB 1000），合计 5000：
      // 账户 1 里 AAA 的目标市值 600、账户 2 里 800 → 合并后 1400/5000 = 28%
      expect(merged.key, 'asset:AAA');
      expect(merged.ratio, closeTo(0.6 * 1000 / 5000 + 0.2 * 4000 / 5000, 1e-9));
      expect(merged.ratio, closeTo(0.28, 1e-9));
      // 合并出来的条目不属于任何账户，回写不了库
      expect(merged.accountId, 0);
      expect(merged.id, isNull);
    });

    test('只有一个账户设过目标时，折算成占全部账户的比例', () {
      final st = build();
      st.allTargets = [
        TargetAlloc(id: 1, accountId: 1, key: 'asset:AAA', label: '甲基金', ratio: 0.5),
      ];
      st.accountFilter = null;
      // 0.5 × 1000/5000 = 0.1
      expect(st.targets.single.ratio, closeTo(0.1, 1e-9));
    });

    test('「全部账户」下写目标不动库（没有归属可写）', () async {
      final st = build();
      st.accountFilter = null;
      await st.setTargetRatio('asset:AAA', '甲基金', 0.5);
      await st.removeTarget('asset:AAA');
      expect(st.allTargets, isEmpty);
    });
  });

  group('模型的账户字段', () {
    test('toMap / fromMap 带上 account_id', () {
      final t = TargetAlloc(id: 7, accountId: 2, key: 'asset:AAA', label: '甲', ratio: 0.3);
      expect(t.toMap()['account_id'], 2);
      final back = TargetAlloc.fromMap(t.toMap());
      expect(back.accountId, 2);
      expect(back.ratio, closeTo(0.3, 1e-9));
      expect(t.copyWith(ratio: 0.4).accountId, 2);
    });

    test('老备份没有 account_id → 归到第一个账户，不会丢', () {
      final back = TargetAlloc.fromMap({'id': 1, 'key': 'asset:AAA', 'ratio': 0.6});
      expect(back.accountId, 1);
    });

    test('account_id 是浮点（JSON 里写成 2.0）也能读成 2', () {
      final back = TargetAlloc.fromMap({'key': 'asset:AAA', 'account_id': 2.0});
      expect(back.accountId, 2);
    });
  });
}
