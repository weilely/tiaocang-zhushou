import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/quote_sync.dart';

/// 刷新行情时的「名字写回」规则
///
/// 这里钉住的是一个真事故：关联 ETF 是临时合成的（没有 id），
/// 旧代码在刷新时对它做 `a.id!`，于是**每次刷新**都弹
/// 「刷新失败：Null check operator used on a null value」。
void main() {
  Asset asset({int? id, String code = '021362', String name = '易方达黄金股'}) =>
      Asset(id: id, code: code, name: name, kind: AssetKind.fund);

  Quote quote(String code, String name) =>
      Quote(code: code, kind: AssetKind.fund, name: name, price: 1.2);

  test('没有 id 的合成标的（关联 ETF）必须跳过，不能拿它去改名', () {
    final r = assetRenames(
      assets: [asset(id: null, code: '517520', name: '')],
      fresh: {'517520': quote('517520', '黄金股ETF永赢')},
    );
    expect(r, isEmpty);
  });

  test('有 id 且行情名不同 → 返回新名字', () {
    final r = assetRenames(
      assets: [asset(id: 7)],
      fresh: {'021362': quote('021362', '易方达黄金股指数发起式A')},
    );
    expect(r, hasLength(1));
    expect(r.single.id, 7);
    expect(r.single.name, '易方达黄金股指数发起式A');
  });

  test('名字一样 / 行情名为空 / 这条代码没有行情 → 都不返回', () {
    expect(
      assetRenames(
        assets: [asset(id: 7, name: '易方达黄金股')],
        fresh: {'021362': quote('021362', '易方达黄金股')},
      ),
      isEmpty,
    );
    expect(
      assetRenames(
        assets: [asset(id: 7)],
        fresh: {'021362': quote('021362', '')},
      ),
      isEmpty,
    );
    expect(
      assetRenames(assets: [asset(id: 7)], fresh: const {}),
      isEmpty,
    );
  });

  test('同一个 id 只算一次（关联 ETF 与被跟踪标的可能撞 code）', () {
    final r = assetRenames(
      assets: [asset(id: 7), asset(id: 7, name: '')],
      fresh: {'021362': quote('021362', '新名字')},
    );
    expect(r, hasLength(1));
  });

  test('混合列表：只挑出有 id 的那些', () {
    final r = assetRenames(
      assets: [
        asset(id: null, code: '517520', name: ''),
        asset(id: 1, code: '021362', name: '旧名'),
        asset(id: null, code: '159263', name: ''),
        asset(id: 2, code: '510300', name: '沪深300ETF华泰柏瑞'),
      ],
      fresh: {
        '517520': quote('517520', '黄金股ETF永赢'),
        '021362': quote('021362', '新名'),
        '159263': quote('159263', '价值ETF易方达'),
        '510300': quote('510300', '沪深300ETF华泰柏瑞'),
      },
    );
    expect(r.map((e) => e.id).toList(), [1]);
    expect(r.single.name, '新名');
  });
}
