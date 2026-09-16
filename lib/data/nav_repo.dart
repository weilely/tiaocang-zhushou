import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'nav_models.dart';

/// 关注列表 / 历史净值 / 现金流水的读写（以扩展挂在 [AppDatabase] 上）
extension NavRepo on AppDatabase {
  // ---------------- 关注 ----------------

  /// 置顶优先，其次按拖动顺序
  Future<List<WatchItem>> watchlist() async {
    final d = await database;
    final rows =
        await d.query('watchlist', orderBy: 'pinned DESC, sort_order ASC, id ASC');
    return rows.map(WatchItem.fromMap).toList();
  }

  Future<bool> isWatched(String code, String kind) async {
    final d = await database;
    final rows = await d.query('watchlist',
        where: 'code = ? AND kind = ?', whereArgs: [code, kind], limit: 1);
    return rows.isNotEmpty;
  }

  Future<int> addWatch(WatchItem w) async {
    final d = await database;
    final maxRow =
        await d.rawQuery('SELECT COALESCE(MAX(sort_order), 0) AS m FROM watchlist');
    final next = ((maxRow.first['m'] as num?)?.toInt() ?? 0) + 1;
    return d.insert(
      'watchlist',
      w.copyWith(sortOrder: next).toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeWatch(int id) async {
    final d = await database;
    await d.delete('watchlist', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setWatchPinned(int id, bool pinned) async {
    final d = await database;
    await d.update('watchlist', {'pinned': pinned ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 拖动排序后整批写回顺序
  Future<void> reorderWatch(List<int> orderedIds) async {
    final d = await database;
    await d.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update('watchlist', {'sort_order': i},
            where: 'id = ?', whereArgs: [orderedIds[i]]);
      }
    });
  }

  Future<void> updateWatchName(int id, String name) async {
    final d = await database;
    await d.update('watchlist', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 历史净值 ----------------

  Future<void> upsertNavPoints(List<NavPoint> points, {int batchSize = 800}) async {
    if (points.isEmpty) return;
    final d = await database;
    for (var i = 0; i < points.length; i += batchSize) {
      final end = (i + batchSize < points.length) ? i + batchSize : points.length;
      final chunk = points.sublist(i, end);
      await d.transaction((txn) async {
        final batch = txn.batch();
        for (final p in chunk) {
          batch.insert('nav_history', p.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
    }
  }

  /// 按日期升序返回某代码的全部历史
  Future<List<NavPoint>> navHistory(String code) async {
    final d = await database;
    final rows = await d.query('nav_history',
        where: 'code = ?', whereArgs: [code], orderBy: 'date ASC');
    return rows.map(NavPoint.fromMap).toList();
  }

  /// 清掉某个代码的全部历史净值（重建用）
  ///
  /// 增量更新只会**补**新日期、不会改已经写错的行 —— 要修净值日期错位
  /// （例：手机时区不是北京时间时老版本把日期整体写早了一天），只能先删后抓。
  Future<void> deleteNavHistory(String code) async {
    final d = await database;
    await d.delete('nav_history', where: 'code = ?', whereArgs: [code]);
  }

  /// 某代码在 `[from, to]`（`yyyy-MM-dd` 闭区间）内每日单位净值
  ///
  /// 交易表单「按交易日期查净值」用：只要 D 前后各 20 天的窗口，
  /// 走 `PRIMARY KEY (code, date)`，不把整段历史读进内存。
  Future<Map<String, double>> navPricesBetween(
    String code,
    String from,
    String to,
  ) async {
    final d = await database;
    final rows = await d.query(
      'nav_history',
      columns: ['date', 'nav'],
      where: 'code = ? AND date >= ? AND date <= ?',
      whereArgs: [code, from, to],
      orderBy: 'date ASC',
    );
    return {
      for (final r in rows)
        if (((r['nav'] as num?)?.toDouble() ?? 0) > 0)
          (r['date'] as String): (r['nav'] as num).toDouble(),
    };
  }

  /// 某代码最新一条的日期（yyyy-MM-dd），没有返回 null —— 增量更新用
  Future<String?> latestNavDate(String code) async {
    final d = await database;
    final rows = await d.rawQuery(
        'SELECT MAX(date) AS d FROM nav_history WHERE code = ?', [code]);
    return rows.first['d'] as String?;
  }

  Future<int> navCount({String? code}) async {
    final d = await database;
    final rows = await d.rawQuery(
      'SELECT COUNT(*) AS c FROM nav_history${code == null ? '' : ' WHERE code = ?'}',
      code == null ? null : [code],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 批量取多只标的的最新区间数据（关注表格用）
  ///
  /// 只取所需的 7 个起点附近 + 最新，避免把整张表读进内存。
  Future<Map<String, List<NavPoint>>> navSamplesFor(
    List<String> codes, {
    required String earliestDate,
  }) async {
    if (codes.isEmpty) return const {};
    final d = await database;
    final out = <String, List<NavPoint>>{};
    // 批大小避免 SQLite 变量上限
    for (var i = 0; i < codes.length; i += 200) {
      final end = (i + 200 < codes.length) ? i + 200 : codes.length;
      final chunk = codes.sublist(i, end);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await d.rawQuery(
        'SELECT * FROM nav_history WHERE code IN ($marks) AND date >= ? ORDER BY code, date ASC',
        [...chunk, earliestDate],
      );
      for (final r in rows) {
        final p = NavPoint.fromMap(r);
        (out[p.code] ??= <NavPoint>[]).add(p);
      }
    }
    return out;
  }

  /// 每个 code 最早的一条记录（算「成立以来」用）
  Future<Map<String, NavPoint>> navEarliestFor(List<String> codes) async {
    if (codes.isEmpty) return const {};
    final d = await database;
    final out = <String, NavPoint>{};
    for (var i = 0; i < codes.length; i += 200) {
      final end = (i + 200 < codes.length) ? i + 200 : codes.length;
      final chunk = codes.sublist(i, end);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await d.rawQuery(
        'SELECT n.* FROM nav_history n '
        'JOIN (SELECT code AS c, MIN(date) AS md FROM nav_history '
        '      WHERE code IN ($marks) GROUP BY code) t '
        '  ON n.code = t.c AND n.date = t.md',
        chunk,
      );
      for (final r in rows) {
        final p = NavPoint.fromMap(r);
        out[p.code] = p;
      }
    }
    return out;
  }

  // ---------------- 现金 ----------------

  Future<List<CashTxn>> cashTxns({int? accountId}) async {
    final d = await database;
    final rows = await d.query('cash_txns',
        where: accountId == null ? null : 'account_id = ?',
        whereArgs: accountId == null ? null : [accountId],
        orderBy: 'date DESC, id DESC');
    return rows.map(CashTxn.fromMap).toList();
  }

  Future<int> saveCashTxn(CashTxn t) async {
    final d = await database;
    if (t.id == null) {
      return d.insert('cash_txns', t.toMap()..remove('id'));
    }
    await d.update('cash_txns', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
    return t.id!;
  }

  Future<void> deleteCashTxn(int id) async {
    final d = await database;
    await d.delete('cash_txns', where: 'id = ?', whereArgs: [id]);
  }

  /// 每个账户的现金余额
  Future<Map<int, double>> cashBalances() async {
    final d = await database;
    final rows = await d.rawQuery(
        'SELECT account_id AS a, SUM(amount) AS s FROM cash_txns GROUP BY account_id');
    return {
      for (final r in rows) (r['a'] as num).toInt(): (r['s'] as num?)?.toDouble() ?? 0,
    };
  }

  Future<void> deleteCashOfAccount(int accountId) async {
    final d = await database;
    await d.delete('cash_txns', where: 'account_id = ?', whereArgs: [accountId]);
  }

  /// 按账户的 [当月收益, 累计收益]
  Future<Map<int, List<double>>> cashIncomeByAccount() async {
    final d = await database;
    final now = DateTime.now();
    final monthStart =
        DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
    final rows = await d.rawQuery(
      "SELECT account_id AS a, "
      "SUM(CASE WHEN date >= ? THEN amount ELSE 0 END) AS m, "
      "SUM(amount) AS t "
      "FROM cash_txns WHERE type = ? GROUP BY account_id",
      [monthStart, CashType.income],
    );
    return {
      for (final r in rows)
        (r['a'] as num).toInt(): [
          (r['m'] as num?)?.toDouble() ?? 0,
          (r['t'] as num?)?.toDouble() ?? 0,
        ],
    };
  }

  /// 删除某笔交易联动生成的现金流水（编辑/删除交易时用）
  Future<void> deleteCashBySrcTxn(int txnId) async {
    final d = await database;
    await d.delete('cash_txns', where: 'src_txn_id = ?', whereArgs: [txnId]);
  }
}
