import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'models.dart';

/// 基础数据库里的一条标的记录（代码 / 名称 / 首拼 / 类型 / 板块）
class SecurityRow {
  final String code;

  /// fund | etf | stock | other（与 [AssetKind] 同名）
  final String kind;
  final String name;

  /// 拼音首字母缩写，大写，如 `HS300ETFHTBR` / `GZMT`
  final String pinyin;

  /// 全拼，小写，如 `guizhoumaotai`
  final String fullPinyin;

  /// 完整类型串：「混合型-灵活」/「股票-上证」
  final String secType;

  /// 一级类型：「混合型」「指数型」「债券型」「股票」…
  final String secClass;

  /// 二级 / 板块：「偏股」「灵活」/「上证」「深证」「创业」「科创」「北证」
  final String secSub;

  /// SH | SZ | BJ | ''（行情接口用）
  final String market;

  /// fund_list | sina | remote
  final String source;
  final int updatedAt;

  const SecurityRow({
    required this.code,
    required this.kind,
    required this.name,
    this.pinyin = '',
    this.fullPinyin = '',
    this.secType = '',
    this.secClass = '',
    this.secSub = '',
    this.market = '',
    this.source = '',
    this.updatedAt = 0,
  });

  AssetKind get assetKind => assetKindFromName(kind);

  /// 「上证」「深证」「北证」等展示用市场名
  String get marketLabel => switch (market) {
        'SH' => '沪市',
        'SZ' => '深市',
        'BJ' => '北证',
        _ => '',
      };

  /// 搜索候选项的副标题：`510300 · ETF/LOF · 指数型-股票 · 沪市`
  String get subtitle {
    final parts = <String>[code, assetKind.label];
    if (secType.isNotEmpty) parts.add(secType);
    // 场内标的有市场信息；场外基金没有
    final ml = marketLabel;
    if (ml.isNotEmpty && !secType.contains(secSub)) parts.add(ml);
    return parts.join(' · ');
  }

  Map<String, Object?> toMap() => {
        'code': code,
        'kind': kind,
        'name': name,
        'pinyin': pinyin,
        'full_pinyin': fullPinyin,
        'sec_type': secType,
        'sec_class': secClass,
        'sec_sub': secSub,
        'market': market,
        'source': source,
        'updated_at': updatedAt,
      };

  factory SecurityRow.fromMap(Map<String, Object?> m) => SecurityRow(
        code: (m['code'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'other',
        name: (m['name'] as String?) ?? '',
        pinyin: (m['pinyin'] as String?) ?? '',
        fullPinyin: (m['full_pinyin'] as String?) ?? '',
        secType: (m['sec_type'] as String?) ?? '',
        secClass: (m['sec_class'] as String?) ?? '',
        secSub: (m['sec_sub'] as String?) ?? '',
        market: (m['market'] as String?) ?? '',
        source: (m['source'] as String?) ?? '',
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );
}

/// 一次标的搜索的结果
class SecuritiesSearchResult {
  final List<SecurityRow> rows;

  /// 结果是否来自联网
  final bool fromRemote;

  /// 是否尝试过联网
  final bool remoteTried;

  /// 联网失败时的错误描述
  final String? error;

  const SecuritiesSearchResult({
    required this.rows,
    this.fromRemote = false,
    this.remoteTried = false,
    this.error,
  });
}

/// 基础数据库的读写（以扩展挂在 [AppDatabase] 上，不改动既有 DAO）
extension SecuritiesRepo on AppDatabase {
  /// 批量写入，按 `(code, kind)` 冲突替换；每批一个事务，避免长事务卡住 UI
  Future<int> upsertSecurities(List<SecurityRow> rows, {int batchSize = 500}) async {
    if (rows.isEmpty) return 0;
    final d = await database;
    var written = 0;
    for (var i = 0; i < rows.length; i += batchSize) {
      final chunk = rows.sublist(i, math.min(i + batchSize, rows.length));
      await d.transaction((txn) async {
        final batch = txn.batch();
        for (final r in chunk) {
          batch.insert('securities', r.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      written += chunk.length;
    }
    return written;
  }

  /// 关键词搜索：代码 / 中文名 / 拼音首字母（前缀）
  Future<List<SecurityRow>> searchSecurities(
    String keyword, {
    String? classFilter,
    String? subFilter,
    int limit = 30,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final d = await database;

    final where = StringBuffer(
        "(code LIKE ? OR name LIKE ? OR pinyin LIKE ?)");
    final args = <Object?>['%$kw%', '%$kw%', '${kw.toUpperCase()}%'];
    if (classFilter != null && classFilter.isNotEmpty) {
      where.write(' AND sec_class = ?');
      args.add(classFilter);
    }
    if (subFilter != null && subFilter.isNotEmpty) {
      where.write(' AND sec_sub = ?');
      args.add(subFilter);
    }
    args.add(kw); // ORDER BY 里精确命中代码的排最前
    args.add('$kw%'); // 代码前缀命中次之
    args.add(limit);

    final rows = await d.rawQuery('''
      SELECT * FROM securities
      WHERE $where
      ORDER BY (code = ?) DESC,
               CASE WHEN code LIKE ? THEN 0 ELSE 1 END,
               length(name),
               code
      LIMIT ?
    ''', args);
    return rows.map(SecurityRow.fromMap).toList();
  }

  /// 按代码精确取一条（OCR 解析用）
  Future<SecurityRow?> securityByCode(String code) async {
    final d = await database;
    final rows = await d.query('securities',
        where: 'code = ?', whereArgs: [code.trim()], limit: 1);
    if (rows.isEmpty) return null;
    return SecurityRow.fromMap(rows.first);
  }

  /// 按名称模糊匹配（OCR 解析用）
  Future<List<SecurityRow>> securitiesByName(String name, {int limit = 5}) async {
    final d = await database;
    final rows = await d.query('securities',
        where: 'name LIKE ?',
        whereArgs: ['%${name.trim()}%'],
        limit: limit);
    return rows.map(SecurityRow.fromMap).toList();
  }

  Future<int> securitiesCount({String? kind}) async {
    final d = await database;
    final r = await d.rawQuery(
      'SELECT COUNT(*) AS c FROM securities${kind == null ? '' : ' WHERE kind = ?'}',
      kind == null ? null : [kind],
    );
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 一级类型 → 条数
  Future<Map<String, int>> securitiesClassCounts() async {
    final d = await database;
    final rows = await d.rawQuery(
        "SELECT sec_class AS k, COUNT(*) AS c FROM securities WHERE sec_class <> '' GROUP BY sec_class ORDER BY c DESC");
    return {for (final r in rows) r['k'] as String: (r['c'] as num).toInt()};
  }

  /// 二级/板块 → 条数，可按一级过滤
  Future<Map<String, int>> securitiesSubCounts({String? classFilter}) async {
    final d = await database;
    final rows = await d.rawQuery(
      "SELECT sec_sub AS k, COUNT(*) AS c FROM securities WHERE sec_sub <> ''"
      '${classFilter == null || classFilter.isEmpty ? '' : ' AND sec_class = ?'}'
      ' GROUP BY sec_sub ORDER BY c DESC',
      classFilter == null || classFilter.isEmpty ? null : [classFilter],
    );
    return {for (final r in rows) r['k'] as String: (r['c'] as num).toInt()};
  }

  /// 一级 → 二级 → 条数（一次查询，供筛选 chip 使用）
  Future<Map<String, Map<String, int>>> securitiesClassSubCounts() async {
    final d = await database;
    final rows = await d.rawQuery(
      "SELECT sec_class AS c, sec_sub AS s, COUNT(*) AS n FROM securities "
      "WHERE sec_class <> '' AND sec_sub <> '' "
      "GROUP BY sec_class, sec_sub ORDER BY n DESC",
    );
    final out = <String, Map<String, int>>{};
    for (final r in rows) {
      final c = r['c'] as String;
      final s = r['s'] as String;
      (out[c] ??= <String, int>{})[s] = (r['n'] as num).toInt();
    }
    return out;
  }

  Future<DateTime?> securitiesUpdatedAt() async {
    final d = await database;
    final r = await d
        .rawQuery('SELECT MAX(updated_at) AS t FROM securities');
    final t = (r.first['t'] as num?)?.toInt();
    if (t == null || t <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(t);
  }

  Future<void> clearSecurities() async {
    final d = await database;
    await d.delete('securities');
  }
}
