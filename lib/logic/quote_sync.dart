import '../data/models.dart';

/// 行情回来之后，哪些标的的名字要写回本地库
///
/// **只处理库里有 id 的标的**。关联 ETF（`AppState.linkAssets`）是为了给场外基金
/// 估涨幅而临时合成的 `Asset`：它有 code 但没有 id、name 也是空的。刷新行情时
/// 顺手拿它去改名就会在 `a.id!` 上抛「Null check operator used on a null value」，
/// 被上层的 catch 兜成「刷新失败：…」——表现就是每次刷新都弹错。
///
/// 这里把判断收成一个纯函数：无 id 直接跳过，同一个 id 只算一次。
List<({int id, String name})> assetRenames({
  required List<Asset> assets,
  required Map<String, Quote> fresh,
}) {
  final out = <({int id, String name})>[];
  final seen = <int>{};
  for (final a in assets) {
    final id = a.id;
    if (id == null || !seen.add(id)) continue;
    final q = fresh[a.code];
    if (q == null) continue;
    if (q.name.isEmpty || q.name == a.name) continue;
    out.add((id: id, name: q.name));
  }
  return out;
}
