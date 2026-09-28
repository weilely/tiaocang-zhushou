import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/txn_form.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/txn_edit_page.dart';
import 'package:provider/provider.dart';

/// 记一笔里的「佣金费率 + 免五」（用户 2026-09-25 要求）
///
/// 费率是**券商（账户）属性**，所以按账户存；免五 = 券商豁免"最低 5 元佣金"。
void main() {
  AppState build({double? wan, bool waive = false}) {
    final st = AppState()..loading = false;
    if (wan != null) st.feeRates[1] = wan;
    if (waive) st.feeWaiveMin.add(1);
    return st;
  }

  group('feeForAmount：成交金额 × 费率', () {
    test('没设费率 → null（不猜，手续费保持用户自己填的）', () {
      final st = build();
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 10000),
          isNull);
    });

    test('场内：万2.5 买 1 万元 = 2.5 元，不足 5 元按 5 元', () {
      final st = build(wan: 2.5);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 10000),
          closeTo(5, 1e-9));
    });

    test('场内：金额够大就按费率算（万2.5 买 4 万元 = 10 元）', () {
      final st = build(wan: 2.5);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.etf, amount: 40000),
          closeTo(10, 1e-9));
    });

    test('免五：不足 5 元也按实际算（万2.5 买 1 万元 = 2.5 元）', () {
      final st = build(wan: 2.5, waive: true);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 10000),
          closeTo(2.5, 1e-9));
    });

    test('场外基金没有"最低 5 元"这一说（万15 买 1 万元 = 15 元）', () {
      final st = build(wan: 15);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.fund, amount: 10000),
          closeTo(15, 1e-9));
    });

    test('费率按账户分开：账户 2 没设就没有', () {
      final st = build(wan: 3);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 100000),
          closeTo(30, 1e-9));
      expect(st.feeForAmount(accountId: 2, kind: AssetKind.stock, amount: 100000),
          isNull);
    });

    test('金额为 0/负数/NaN → null', () {
      final st = build(wan: 2.5);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 0),
          isNull);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: -100),
          isNull);
      expect(
          st.feeForAmount(
              accountId: 1, kind: AssetKind.stock, amount: double.nan),
          isNull);
    });

    test('钱落到分（万1 买 12345 元 = 1.23 元 → 不足 5 元按 5 元）', () {
      final st = build(wan: 1, waive: true);
      expect(st.feeForAmount(accountId: 1, kind: AssetKind.stock, amount: 12345),
          closeTo(1.23, 1e-9));
    });
  });

  // 用户 2026-09-28：「费率还显示佣金费率万分之几，还有免五，区分一下场内和场外的
  // 费率设置，申购，赎回，提示在框线上显示，风格统一」
  group('场外基金：申购费 / 赎回费（按基金代码存，%）', () {
    AppState fund({double? sub, double? redeem}) {
      final st = AppState()..loading = false;
      if (sub != null) st.subFeeRates['025497'] = sub;
      if (redeem != null) st.redeemFeeRates['025497'] = redeem;
      return st;
    }

    test('买入按**申购费率**算：0.1% × 10 万元 = 100 元', () {
      final st = fund(sub: 0.1);
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '025497',
            kind: AssetKind.fund,
            type: TxnType.buy,
            amount: 100000),
        closeTo(100, 1e-9),
      );
    });

    test('卖出按**赎回费率**算（两套互不干扰）', () {
      final st = fund(sub: 0.1, redeem: 0.5);
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '025497',
            kind: AssetKind.fund,
            type: TxnType.sell,
            amount: 10000),
        closeTo(50, 1e-9),
      );
      // 只设了申购费、没设赎回费 → 卖出没有预测（不拿申购费凑）
      final onlySub = fund(sub: 0.1);
      expect(
        onlySub.feeForTxn(
            accountId: 1,
            code: '025497',
            kind: AssetKind.fund,
            type: TxnType.sell,
            amount: 10000),
        isNull,
      );
    });

    test('场外**没有最低 5 元**、也不吃免五那套', () {
      final st = fund(sub: 0.001); // 万分之0.1
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '025497',
            kind: AssetKind.fund,
            type: TxnType.buy,
            amount: 10000),
        closeTo(0.1, 1e-9),
      );
    });

    test('按基金代码分开存：别的基金没设就没有', () {
      final st = fund(sub: 0.1);
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '021362',
            kind: AssetKind.fund,
            type: TxnType.buy,
            amount: 10000),
        isNull,
      );
    });

    test('场内不受影响：仍按账户佣金率 + 免五（不足 5 元按 5 元）', () {
      final st = fund(sub: 0.1);
      st.feeRates[1] = 2.5;
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '510300',
            kind: AssetKind.etf,
            type: TxnType.buy,
            amount: 10000),
        closeTo(5, 1e-9),
        reason: '场外的申购费率不该影响场内',
      );
      // 场内没设佣金率 → 不拿场外的费率顶（ETF 也没有税费）
      final st2 = fund(sub: 0.1);
      expect(
        st2.feeForTxn(
            accountId: 9,
            code: '025497',
            kind: AssetKind.etf,
            type: TxnType.buy,
            amount: 10000),
        isNull,
      );
    });
  });

  // 用户 2026-09-28：「场内交易费用卖出时考虑卖出股票印花税和过手费没有」
  group('场内税费：股票印花税 + 过户费', () {
    test('印花税 0.05% 只有**卖出股票**才收（10 万元 → 50 元）', () {
      expect(
        exchangeTaxes(
            kind: AssetKind.stock, type: TxnType.sell, amount: 100000),
        closeTo(50 + 1, 1e-9), // 印花税 50 ＋ 过户费 1
      );
      expect(
        exchangeTaxes(kind: AssetKind.stock, type: TxnType.buy, amount: 100000),
        closeTo(1, 1e-9), // 买入只有过户费
      );
    });

    test('过户费 0.001% 双向都收', () {
      expect(
        exchangeTaxes(kind: AssetKind.stock, type: TxnType.buy, amount: 50000),
        closeTo(0.5, 1e-9),
      );
      expect(
        exchangeTaxes(kind: AssetKind.stock, type: TxnType.sell, amount: 50000),
        closeTo(0.5 + 25, 1e-9),
      );
    });

    test('ETF / LOF / 场外基金：印花税与过户费都不收', () {
      for (final k in [AssetKind.etf, AssetKind.fund, AssetKind.other]) {
        expect(exchangeTaxes(kind: k, type: TxnType.sell, amount: 100000), 0,
            reason: '${k.name} 不该收税费');
      }
    });

    test('金额非法 → 0', () {
      expect(exchangeTaxes(kind: AssetKind.stock, type: TxnType.sell, amount: 0), 0);
      expect(exchangeTaxes(kind: AssetKind.stock, type: TxnType.buy, amount: -1), 0);
    });

    test('预测手续费 = 佣金 + 税费（股票卖出 10 万、万2.5 佣金）', () {
      final st = AppState()..loading = false;
      st.feeRates[1] = 2.5;
      expect(
        st.feeForTxn(
            accountId: 1,
            code: '000001',
            kind: AssetKind.stock,
            type: TxnType.sell,
            amount: 100000),
        closeTo(25 + 51, 1e-9),
      );
      // 没设佣金率也要收税费（法定费用，与佣金率无关）
      final st2 = AppState()..loading = false;
      expect(
        st2.feeForTxn(
            accountId: 1,
            code: '000001',
            kind: AssetKind.stock,
            type: TxnType.sell,
            amount: 100000),
        closeTo(51, 1e-9),
      );
      // 买入同一只股票：只有佣金 + 过户费
      expect(
        st2.feeForTxn(
            accountId: 1,
            code: '000001',
            kind: AssetKind.stock,
            type: TxnType.buy,
            amount: 100000),
        closeTo(1, 1e-9),
      );
    });
  });

  // 用户 2026-09-25：「把佣金费率和免五开关放在金额后面，手续费分两栏，预测和实际，
  // 同一行显示，预测在前，不可改，实际默认为 0，一键导入预测值，可改，作为真实手续费计入成本」
  group('记一笔的费率区（布局）', () {
    testWidgets('场内（ETF）：佣金费率 + 免五 + 手续费两栏，窄屏大字体不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final st = AppState()..loading = false;
      st.accounts = [Account(id: 1, name: '测试账户')];
      st.accountFilter = 1;
      st.feeRates[1] = 2.5;

      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: st,
        child: MaterialApp(
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: TxnEditPage(
            presetAccountId: 1,
            presetType: TxnType.buy,
            presetAsset: Asset(
                code: '510300', name: '沪深300ETF', kind: AssetKind.etf),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('佣金费率（万分之几）'), findsOneWidget);
      expect(find.text('免五'), findsOneWidget);
      expect(find.text('手续费（预测）'), findsOneWidget);
      expect(find.text('手续费（实际）'), findsOneWidget);
      // 实际默认为 0
      expect(find.text('0'), findsWidgets);
      expect(tester.takeException(), isNull, reason: '窄屏 + 字体 1.3 倍不许溢出');
    });

    testWidgets('标的类型选到场外基金 → 框线上写「申购费率（%）」，没有免五', (tester) async {
      tester.view.physicalSize = const Size(400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final st = AppState()..loading = false;
      st.accounts = [Account(id: 1, name: '测试账户')];
      st.accountFilter = 1;
      st.feeRates[1] = 0.85;
      st.subFeeRates['025497'] = 0.1;

      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: st,
        child: MaterialApp(home: const TxnEditPage()),
      ));
      await tester.pumpAndSettle();

      // 默认（标的类型 = fund）就是场外口径
      expect(find.text('申购费率（%）'), findsOneWidget);
      expect(find.text('佣金费率（万分之几）'), findsNothing);
      expect(find.text('免五'), findsNothing, reason: '最低 5 元是券商佣金概念，场外没有');

      // 切到卖出 → 赎回费改成「按持有天数档自动算」，不再手填固定费率
      await tester.tap(find.text('卖出'));
      await tester.pumpAndSettle();
      expect(find.text('赎回费档位'), findsOneWidget);
      expect(find.text('申购费率（%）'), findsNothing);
      expect(find.text('档位'), findsOneWidget, reason: '能从这里看分布/改档位');
    });
  });
}
