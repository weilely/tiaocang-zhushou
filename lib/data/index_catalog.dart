/// 「指数目录」取数：**中证指数官网的官方全量指数表**（2026-09-29 打通）。
///
/// `POST https://www.csindex.com.cn/csindex-home/index-list/query-index-item`
/// 请求体三层（**平铺参数会返回 `400 Parameter Errors`**，这是从它前端 JS
/// 里扒出来的真实形状）：
/// ```json
/// {"sorter":{"sortField":"null","sortOrder":null},
///  "pager":{"pageNum":1,"pageSize":1000},
///  "indexFilter":{"ifCustomized":null,"ifTracked":null,"ifWeightCapped":null,
///                 "indexCompliance":null,"hotSpot":null,"indexClassify":null,
///                 "currency":null,"region":null,"indexSeries":null}}
/// ```
/// 实测：**不需要 UA / Referer**（Dart 直接能调）；`pageSize=1000` 分页有效
/// （`pageNum` 1→4 拿全 3001 条，代码严格递进），每页约 760KB / 4~9 秒 →
/// **并发翻页 + 落盘缓存**（见 [IndexCatalogSource]）。
///
/// ⚠️ **它自己不做排序/筛选**：`sortField` 传真字段名（monthlyReturn /
/// consNumber）会返回 0 条，`indexFilter.indexSeries` 传数组也是 0 条 ——
/// 所以「分类、排序、搜索」**一律在本地做**（这也正好离线可用）。
///
/// ⚠️ **表里没有估值/股息率**（字段只有代码/名称/系列/资产类别/分类/地区/
/// 币种/成分数/最新点位/月度收益/发布日期）→ 股息率仍要按指数逐个去取
/// （蛋卷 `index_eva`、中证 `indicator.xls`，见 `index_eva.dart`）。
///
/// ⚠️ **覆盖范围是中证系的指数**（中证 2370 / 上证 552 / 中基协 43 / 中华交易 13 /
/// 新三板 10 / 深证 6 / 北证 2）：**国证系（980xxx）与恒生系不在里面**，它们本来
/// 也没有股息率源。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 缓存多久算新鲜（目录变化很慢，一周足够）
const Duration kIndexCatalogTtl = Duration(days: 7);

double? _numOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim());
}

int? _intOrNull(Object? v) => _numOrNull(v)?.toInt();

String _str(Object? v) {
  if (v == null) return '';
  final s = v.toString().trim();
  return s == '-' ? '' : s; // 官网把"没有"写成 `-`
}

/// 目录里的一条指数
class IndexCatalogItem {
  final String code;
  final String name;
  final String nameEn;

  /// 指数系列，如 `中证系列指数` / `上证系列指数`
  final String series;

  /// 资产类别，如 `股票` / `固定收益` / `多资产` / `基金` / `期货`
  final String assetClass;

  /// 细分类，如 `规模` / `行业` / `主题` / `策略` / `风格` / `信用债`
  final String classify;

  /// 地区，如 `境内` / `香港` / `全球` / `沪深港`
  final String region;
  final String currency;

  /// 成分数（债券指数往往没有）
  final int? consNumber;

  /// 最新点位与月度收益（%），官网自带 —— 用它排序不需要额外请求
  final double? latestClose;
  final double? monthlyReturn;

  /// 发布日期（`yyyy-MM-dd`，原样保留）
  final String publishDate;

  /// 是否被基金跟踪（官网 `ifTracked == 是`）
  final bool tracked;

  const IndexCatalogItem({
    required this.code,
    required this.name,
    this.nameEn = '',
    this.series = '',
    this.assetClass = '',
    this.classify = '',
    this.region = '',
    this.currency = '',
    this.consNumber,
    this.latestClose,
    this.monthlyReturn,
    this.publishDate = '',
    this.tracked = false,
  });

  static IndexCatalogItem? fromRow(Object? row) {
    if (row is! Map) return null;
    final code = _str(row['indexCode']).isEmpty
        ? _str(row['key'])
        : _str(row['indexCode']);
    final name = _str(row['indexName']);
    if (code.isEmpty || name.isEmpty) return null; // 缺代码或缺名字 = 这条没用
    return IndexCatalogItem(
      code: code,
      name: name,
      nameEn: _str(row['indexNameEn']),
      series: _str(row['indexSeries']),
      assetClass: _str(row['assetsClassify']),
      classify: _str(row['indexClassify']),
      region: _str(row['region']),
      currency: _str(row['currency']),
      consNumber: _intOrNull(row['consNumber']),
      latestClose: _numOrNull(row['latestClose']),
      monthlyReturn: _numOrNull(row['monthlyReturn']),
      publishDate: _str(row['publishDate']),
      tracked: _str(row['ifTracked']) == '是',
    );
  }

  /// 搜索用的小写串（代码 + 中英文名）
  String get searchKey => '$code $name $nameEn'.toLowerCase();

  Map<String, Object?> toJson() => {
        'c': code,
        'n': name,
        'ne': nameEn,
        's': series,
        'a': assetClass,
        'k': classify,
        'r': region,
        'cu': currency,
        'cn': consNumber,
        'lc': latestClose,
        'mr': monthlyReturn,
        'pd': publishDate,
        't': tracked,
      };

  static IndexCatalogItem? fromCache(Map<String, Object?> m) {
    final code = _str(m['c']);
    final name = _str(m['n']);
    if (code.isEmpty || name.isEmpty) return null;
    return IndexCatalogItem(
      code: code,
      name: name,
      nameEn: _str(m['ne']),
      series: _str(m['s']),
      assetClass: _str(m['a']),
      classify: _str(m['k']),
      region: _str(m['r']),
      currency: _str(m['cu']),
      consNumber: _intOrNull(m['cn']),
      latestClose: _numOrNull(m['lc']),
      monthlyReturn: _numOrNull(m['mr']),
      publishDate: _str(m['pd']),
      tracked: m['t'] == true,
    );
  }
}

/// 可排序的字段
enum IndexSortField {
  code('代码'),
  name('名称'),
  monthlyReturn('月度收益'),
  consNumber('成分数'),
  latestClose('点位'),
  publishDate('发布日期');

  const IndexSortField(this.label);
  final String label;
}

/// 一份目录 + 本地查询能力（分类取值、搜索、排序全在本地）
class IndexCatalog {
  final List<IndexCatalogItem> items;
  final DateTime fetchedAt;

  const IndexCatalog(this.items, this.fetchedAt);

  bool get isEmpty => items.isEmpty;

  /// 按某个维度取分类清单（不含空值，按条数从多到少）
  List<String> dimensions(String Function(IndexCatalogItem) pick) {
    final cnt = <String, int>{};
    for (final it in items) {
      final v = pick(it);
      if (v.isEmpty) continue;
      cnt[v] = (cnt[v] ?? 0) + 1;
    }
    final keys = cnt.keys.toList()..sort((a, b) {
        final c = cnt[b]!.compareTo(cnt[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return keys;
  }

  List<String> get series => dimensions((e) => e.series);
  List<String> get assetClasses => dimensions((e) => e.assetClass);
  List<String> get classifies => dimensions((e) => e.classify);
  List<String> get regions => dimensions((e) => e.region);

  /// 搜索 + 筛选 + 排序。**空关键词 + 空筛选 = 全部**。
  ///
  /// 排序时**缺值的永远排在最后**（正序倒序都一样）—— 缺数据不该装成"最小/最大"。
  List<IndexCatalogItem> query({
    String keyword = '',
    Set<String> series = const {},
    Set<String> assetClasses = const {},
    Set<String> classifies = const {},
    Set<String> regions = const {},
    bool trackedOnly = false,
    IndexSortField sort = IndexSortField.code,
    bool desc = false,
    int limit = 0,
  }) {
    final kw = keyword.trim().toLowerCase();
    final terms = kw.isEmpty
        ? const <String>[]
        : kw.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    var list = items.where((it) {
      if (series.isNotEmpty && !series.contains(it.series)) return false;
      if (assetClasses.isNotEmpty && !assetClasses.contains(it.assetClass)) {
        return false;
      }
      if (classifies.isNotEmpty && !classifies.contains(it.classify)) {
        return false;
      }
      if (regions.isNotEmpty && !regions.contains(it.region)) return false;
      if (trackedOnly && !it.tracked) return false;
      if (terms.isNotEmpty) {
        // 多词全命中（空格分词）：`中证 红利` 能搜到"中证红利"
        final key = it.searchKey;
        for (final t in terms) {
          if (!key.contains(t)) return false;
        }
      }
      return true;
    }).toList();

    double? numOf(IndexCatalogItem it) => switch (sort) {
          IndexSortField.latestClose => it.latestClose,
          IndexSortField.monthlyReturn => it.monthlyReturn,
          _ => null,
        };
    int? intOf(IndexCatalogItem it) => switch (sort) {
          IndexSortField.consNumber => it.consNumber,
          _ => null,
        };

    list.sort((a, b) {
      int r;
      if (sort == IndexSortField.code || sort == IndexSortField.name) {
        r = (sort == IndexSortField.code ? a.code : a.name)
            .compareTo(sort == IndexSortField.code ? b.code : b.name);
      } else if (sort == IndexSortField.publishDate) {
        r = a.publishDate.compareTo(b.publishDate);
      } else if (sort == IndexSortField.consNumber) {
        final x = intOf(a), y = intOf(b);
        if (x == null && y == null) {
          r = 0;
        } else if (x == null) {
          return 1; // 缺值沉底（不受 desc 影响）
        } else if (y == null) {
          return -1;
        } else {
          r = x.compareTo(y);
        }
      } else {
        final x = numOf(a), y = numOf(b);
        if (x == null && y == null) {
          r = 0;
        } else if (x == null) {
          return 1;
        } else if (y == null) {
          return -1;
        } else {
          r = x.compareTo(y);
        }
      }
      if (r == 0) r = a.code.compareTo(b.code); // 稳定：同值时按代码
      return desc ? -r : r;
    });
    if (limit > 0 && list.length > limit) list = list.sublist(0, limit);
    return list;
  }
}

/// 「指数目录」取数客户端：并发翻页拉全量 + 落盘缓存
class IndexCatalogSource {
  final http.Client _client;
  final String base;

  /// 缓存目录提供者（测试里注入临时目录）
  final Future<Directory> Function() _dirOf;

  IndexCatalogSource({
    http.Client? client,
    this.base = 'https://www.csindex.com.cn',
    Future<Directory> Function()? cacheDir,
  })  : _client = client ?? http.Client(),
        _dirOf = cacheDir ?? getApplicationSupportDirectory;

  static const _path = '/csindex-home/index-list/query-index-item';

  static const _filter = {
    'ifCustomized': null,
    'ifTracked': null,
    'ifWeightCapped': null,
    'indexCompliance': null,
    'hotSpot': null,
    'indexClassify': null,
    'currency': null,
    'region': null,
    'indexSeries': null,
  };

  /// 拉一页（`pageNum` 从 1 开始）。返回 (条目, 总条数)
  Future<(List<IndexCatalogItem>, int)> fetchPage(
    int pageNum, {
    int pageSize = 1000,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final body = jsonEncode({
      'sorter': {'sortField': 'null', 'sortOrder': null},
      'pager': {'pageNum': pageNum, 'pageSize': pageSize},
      'indexFilter': _filter,
    });
    final resp = await _client
        .post(Uri.parse('$base$_path'),
            headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw HttpException('指数目录 HTTP ${resp.statusCode}');
    }
    return parseIndexCatalogResponse(utf8.decode(resp.bodyBytes));
  }

  /// 并发翻页拉全量（首屏要等，约 10 秒；拉完就落盘，之后离线秒开）
  Future<IndexCatalog> fetchAll({
    int pageSize = 1000,
    void Function(int done, int total)? onProgress,
  }) async {
    final first = await fetchPage(1, pageSize: pageSize);
    final total = first.$2 > 0 ? first.$2 : first.$1.length;
    final pages = (total + pageSize - 1) ~/ pageSize;
    final all = <IndexCatalogItem>[...first.$1];
    onProgress?.call(1, pages);
    if (pages > 1) {
      final rest = await Future.wait([
        for (var i = 2; i <= pages; i++)
          fetchPage(i, pageSize: pageSize).then((r) {
            onProgress?.call(i, pages);
            return r.$1;
          }),
      ]);
      for (final list in rest) {
        all.addAll(list);
      }
    }
    final byCode = <String, IndexCatalogItem>{};
    for (final it in all) {
      byCode[it.code] = it;
    }
    return IndexCatalog(byCode.values.toList(), DateTime.now());
  }

  File _cachedFile(Directory dir) => File(p.join(dir.path, 'index_catalog.json'));

  /// 读缓存（没有/坏了/型号对不上都返回 null，**不抛**）
  Future<IndexCatalog?> loadCache({bool allowStale = true}) async {
    try {
      final f = _cachedFile(await _dirOf());
      if (!f.existsSync()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final at = DateTime.tryParse('${j['fetchedAt']}');
      if (at == null) return null;
      if (!allowStale && DateTime.now().difference(at) > kIndexCatalogTtl) {
        return null;
      }
      final raw = j['items'];
      if (raw is! List) return null;
      final items = <IndexCatalogItem>[];
      for (final r in raw) {
        final it = r is Map ? IndexCatalogItem.fromCache(r.cast<String, Object?>()) : null;
        if (it != null) items.add(it);
      }
      if (items.isEmpty) return null;
      return IndexCatalog(items, at);
    } catch (_) {
      return null;
    }
  }

  /// 拉全量并写缓存；**拉失败时如果有旧缓存就回退用它**（标成旧数据由界面说）
  Future<IndexCatalog> refresh() async {
    final fresh = await fetchAll();
    await saveCache(fresh);
    return fresh;
  }

  Future<void> saveCache(IndexCatalog c) async {
    try {
      final dir = await _dirOf();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = _cachedFile(dir);
      await f.writeAsString(jsonEncode({
        'fetchedAt': c.fetchedAt.toIso8601String(),
        'items': [for (final it in c.items) it.toJson()],
      }));
    } catch (_) {
      // 缓存写不进去不影响本次使用
    }
  }

  /// 页面入口：有新鲜缓存就用，否则拉一次；拉失败回退旧缓存
  Future<IndexCatalog?> load({void Function(int done, int total)? onProgress}) async {
    final cached = await loadCache(allowStale: false);
    if (cached != null) return cached;
    try {
      return await fetchAll(onProgress: onProgress).then((c) async {
        await saveCache(c);
        return c;
      });
    } catch (_) {
      final stale = await loadCache();
      if (stale != null) return stale;
      rethrow;
    }
  }
}

/// 解析一次响应（`total` + `data[]`）—— 形状照 2026-09-29 实测响应
(List<IndexCatalogItem>, int) parseIndexCatalogResponse(String body) {
  Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    return (const <IndexCatalogItem>[], 0);
  }
  if (j is! Map) return (const <IndexCatalogItem>[], 0);
  final rows = j['data'];
  final items = <IndexCatalogItem>[];
  if (rows is List) {
    for (final r in rows) {
      final it = IndexCatalogItem.fromRow(r);
      if (it != null) items.add(it);
    }
  }
  final total = _intOrNull(j['total']) ?? items.length;
  return (items, total);
}
