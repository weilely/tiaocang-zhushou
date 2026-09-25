import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/state/app_state.dart';

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
}
