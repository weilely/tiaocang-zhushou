import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/portfolio.dart';

/// T+1 可卖份额（用户 2026-09-25：「关于 T+1 份额卖出的事」）
///
/// 口径：场内（股票/ETF）T+1 交易制度、场外基金 T+1 确认 —— 合起来就是
/// **当日买入的份额/股数当天不能卖**，以前买的都能卖。
void main() {
  Asset asset(AssetKind kind) => Asset(
        id: 1,
        code: kind == AssetKind.stock ? '000001' : '110011',
        name: '测试',
        kind: kind,
      );

  Txn txn({
    required TxnType type,
    required DateTime date,
    required double shares,
  }) =>
      Txn(
        accountId: 1,
        assetId: 1,
        type: type,
        date: date,
        amount: shares,
        shares: shares,
        price: 1,
      );

  Position pos({
    required List<Txn> txns,
    double shares = 800,
    AssetKind kind = AssetKind.stock,
  }) =>
      Position(
        accountId: 1,
        asset: asset(kind),
        shares: shares,
        cost: shares,
        realized: 0,
        invested: shares,
        returned: 0,
        quote: null,
        txns: txns,
      );

  final today = DateTime(2026, 9, 25, 14, 30);
  final yesterday = DateTime(2026, 9, 24, 9, 30);

  test('昨天买的：800 股全都能卖', () {
    final p = pos(txns: [
      txn(type: TxnType.buy, date: yesterday, shares: 800),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(800, 1e-9));
  });

  test('今天买的：一股都不能卖（T+1）', () {
    final p = pos(txns: [
      txn(type: TxnType.buy, date: today, shares: 800),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(0, 1e-9));
  });

  test('今天又补了 300 股：老 500 股能卖，新 300 股不能', () {
    final p = pos(shares: 800, txns: [
      txn(type: TxnType.buy, date: yesterday, shares: 500),
      txn(type: TxnType.buy, date: today, shares: 300),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(500, 1e-9));
  });

  test('隔天就能全卖了（同一笔流水，第二天再看）', () {
    final p = pos(txns: [
      txn(type: TxnType.buy, date: today, shares: 800),
    ]);
    expect(sellableShares(p, asOf: today.add(const Duration(days: 1))),
        closeTo(800, 1e-9));
  });

  test('今天卖出只减少持仓，不会把可卖算成负数', () {
    // 昨天买 800、今天买 300、今天卖 500 → 持仓 600，今天买的 300 不能卖
    final p = pos(shares: 600, txns: [
      txn(type: TxnType.buy, date: yesterday, shares: 800),
      txn(type: TxnType.buy, date: today, shares: 300),
      txn(type: TxnType.sell, date: today, shares: 500),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(300, 1e-9));
  });

  test('场外基金同一个规则（当日买入未确认不能赎回）', () {
    final p = pos(kind: AssetKind.fund, shares: 10000, txns: [
      txn(type: TxnType.buy, date: today, shares: 10000),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(0, 1e-9));
  });

  test('没有当日买入时，可卖 = 全部持仓（用户库里那两笔就是这种）', () {
    final p = pos(kind: AssetKind.fund, shares: 10000, txns: [
      txn(type: TxnType.buy, date: DateTime(2026, 1, 14), shares: 10000),
    ]);
    expect(sellableShares(p, asOf: today), closeTo(10000, 1e-9));
  });
}
