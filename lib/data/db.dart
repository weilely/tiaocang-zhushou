import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 本地 SQLite 存储（app 私有目录，无需任何权限）
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const String _dbName = 'invest_tracker.db';

  /// v2 securities，v3 dca_plans，v4 watchlist/nav_history/cash_txns，
  /// v5 给 cash_txns 加 src_txn_id（交易联动的现金流水），
  /// v6 给 assets 加 link_code，v7 macro_history（股债利差每日累积）
  static const int _dbVersion = 7;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _onCreate(Database d, int version) async {
    await d.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        note TEXT NOT NULL DEFAULT ''
      )
    ''');

    await d.execute('''
      CREATE TABLE assets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL,
        market TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '',
        link_code TEXT NOT NULL DEFAULT '',
        UNIQUE (code, kind)
      )
    ''');

    await d.execute('''
      CREATE TABLE txns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL,
        asset_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        date INTEGER NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        shares REAL NOT NULL DEFAULT 0,
        price REAL NOT NULL DEFAULT 0,
        fee REAL NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT ''
      )
    ''');
    await d.execute('CREATE INDEX idx_txns_account ON txns (account_id)');
    await d.execute('CREATE INDEX idx_txns_asset ON txns (asset_id)');
    await d.execute('CREATE INDEX idx_txns_date ON txns (date)');

    await d.execute('''
      CREATE TABLE quotes (
        code TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        price REAL NOT NULL DEFAULT 0,
        prev_close REAL NOT NULL DEFAULT 0,
        change_pct REAL NOT NULL DEFAULT 0,
        price_type TEXT NOT NULL DEFAULT 'price',
        info_date TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      )
    ''');

    await d.execute('''
      CREATE TABLE targets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL DEFAULT '',
        ratio REAL NOT NULL DEFAULT 0
      )
    ''');

    await d.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // 基础数据库（代码/名称/首拼/类型/板块），由「数据维护中心」按需联网更新
    await _createSecuritiesTable(d);

    // 定投计划
    await _createDcaTable(d);

    // 关注 / 历史净值 / 现金
    await _createWatchTable(d);
    await _createNavTable(d);
    await _createCashTable(d);

    // 宏观估值（股债利差）每日累积
    await _createMacroTable(d);

    // 预置一个默认账户，开箱即用
    await d.insert('accounts', {'name': '默认账户', 'note': '我的主账户'});
  }

  /// v1 → v2 加 securities，v2 → v3 加 dca_plans。
  /// 全程 `IF NOT EXISTS`，**幂等且不触碰任何既有表** —— 升级不会影响已有持仓数据。
  Future<void> _onUpgrade(Database d, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSecuritiesTable(d);
    }
    if (oldVersion < 3) {
      await _createDcaTable(d);
    }
    if (oldVersion < 4) {
      await _createWatchTable(d);
      await _createNavTable(d);
      await _createCashTable(d);
    }
    if (oldVersion < 5) {
      // 老库补列；新库在 _createCashTable 里已带此列
      await _addColumnIfMissing(d, 'cash_txns', 'src_txn_id', 'INTEGER');
    }
    if (oldVersion < 6) {
      // 调仓页要用「关联 ETF」估场外基金的当日涨幅
      await _addColumnIfMissing(d, 'assets', 'link_code', "TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 7) {
      await _createMacroTable(d);
    }
  }

  /// 幂等补列：已存在则跳过（`ALTER TABLE ADD COLUMN` 重复执行会报错）
  Future<void> _addColumnIfMissing(
      Database d, String table, String column, String type) async {
    final rows = await d.rawQuery('PRAGMA table_info($table)');
    final has = rows.any((r) => (r['name'] as String?) == column);
    if (!has) {
      await d.execute('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }

  Future<void> _createWatchTable(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS watchlist (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        code       TEXT    NOT NULL,
        kind       TEXT    NOT NULL,
        name       TEXT    NOT NULL DEFAULT '',
        market     TEXT    NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        pinned     INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        UNIQUE (code, kind)
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_watch_sort ON watchlist (pinned DESC, sort_order ASC)');
  }

  Future<void> _createNavTable(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS nav_history (
        code       TEXT    NOT NULL,
        date       TEXT    NOT NULL,
        nav        REAL    NOT NULL,
        acc_nav    REAL    NOT NULL DEFAULT 0,
        change_pct REAL    NOT NULL DEFAULT 0,
        dividend   TEXT    NOT NULL DEFAULT '',
        PRIMARY KEY (code, date)
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_nav_date ON nav_history (date)');
  }

  /// 宏观估值每日一点（股债利差）
  ///
  /// 为什么要本地存：股债利差最有用的用法是"当前处于历史多少分位"，
  /// 而免费可得的数据源里**国债收益率只有 2023-05 起的历史**（东财 171 市场），
  /// 样本太短。从接入那天起每天记一个点，历史就会随时间长起来。
  Future<void> _createMacroTable(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS macro_history (
        date      TEXT PRIMARY KEY,
        hs300_pe  REAL NOT NULL DEFAULT 0,
        cn10y     REAL NOT NULL DEFAULT 0,
        erp       REAL NOT NULL DEFAULT 0
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_macro_date ON macro_history (date)');
  }

  Future<void> _createCashTable(Database d) async {    await d.execute('''
      CREATE TABLE IF NOT EXISTS cash_txns (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL,
        type       TEXT    NOT NULL,
        amount     REAL    NOT NULL,
        date       INTEGER NOT NULL,
        note       TEXT    NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        src_txn_id INTEGER
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_cash_account ON cash_txns (account_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_cash_date ON cash_txns (date)');
  }

  Future<void> _createDcaTable(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS dca_plans (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id    INTEGER NOT NULL,
        asset_id      INTEGER NOT NULL,
        amount        REAL    NOT NULL,
        frequency     TEXT    NOT NULL,
        day_of_period INTEGER NOT NULL,
        start_date    INTEGER NOT NULL,
        last_run_date INTEGER NOT NULL DEFAULT 0,
        enabled       INTEGER NOT NULL DEFAULT 1,
        note          TEXT    NOT NULL DEFAULT '',
        created_at    INTEGER NOT NULL
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_dca_asset ON dca_plans (asset_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_dca_enabled ON dca_plans (enabled)');
  }

  Future<void> _createSecuritiesTable(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS securities (
        code        TEXT    NOT NULL,
        kind        TEXT    NOT NULL,
        name        TEXT    NOT NULL,
        pinyin      TEXT    NOT NULL DEFAULT '',
        full_pinyin TEXT    NOT NULL DEFAULT '',
        sec_type    TEXT    NOT NULL DEFAULT '',
        sec_class   TEXT    NOT NULL DEFAULT '',
        sec_sub     TEXT    NOT NULL DEFAULT '',
        market      TEXT    NOT NULL DEFAULT '',
        source      TEXT    NOT NULL DEFAULT '',
        updated_at  INTEGER NOT NULL,
        PRIMARY KEY (code, kind)
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sec_pinyin ON securities (pinyin)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sec_name ON securities (name)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sec_class ON securities (sec_class)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sec_sub ON securities (sec_sub)');
  }

  // ---------------- 账户 ----------------

  Future<List<Account>> accounts() async {
    final d = await database;
    final rows = await d.query('accounts', orderBy: 'id ASC');
    return rows.map(Account.fromMap).toList();
  }

  Future<int> saveAccount(Account a) async {
    final d = await database;
    if (a.id == null) {
      return d.insert('accounts', a.toMap()..remove('id'));
    }
    await d.update('accounts', a.toMap(), where: 'id = ?', whereArgs: [a.id]);
    return a.id!;
  }

  Future<void> deleteAccount(int id) async {
    final d = await database;
    await d.delete('txns', where: 'account_id = ?', whereArgs: [id]);
    await d.delete('accounts', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 标的 ----------------

  Future<List<Asset>> assets() async {
    final d = await database;
    final rows = await d.query('assets', orderBy: 'code ASC');
    return rows.map(Asset.fromMap).toList();
  }

  /// 按 (code, kind) 去重写入，返回资产 id
  Future<int> upsertAsset(Asset a) async {
    final d = await database;
    if (a.id != null) {
      final map = a.toMap();
      // 关联 ETF 只由调仓页维护：调用方（记一笔、CSV 导入等）拿不到它，
      // 传空值时不能把库里已有的关联关系抹掉
      if (a.linkCode.isEmpty) map.remove('link_code');
      await d.update('assets', map, where: 'id = ?', whereArgs: [a.id]);
      return a.id!;
    }
    final existing = await d.query(
      'assets',
      where: 'code = ? AND kind = ?',
      whereArgs: [a.code, a.kind.name],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      final updates = <String, Object?>{};
      // 名称可能从行情接口更新
      if (a.name.isNotEmpty && a.name != existing.first['name']) {
        updates['name'] = a.name;
      }
      // 分类由用户设置，非空时才覆盖
      if (a.category.isNotEmpty && a.category != existing.first['category']) {
        updates['category'] = a.category;
      }
      if (a.market.isNotEmpty && a.market != existing.first['market']) {
        updates['market'] = a.market;
      }
      if (a.linkCode.isNotEmpty && a.linkCode != existing.first['link_code']) {
        updates['link_code'] = a.linkCode;
      }
      if (updates.isNotEmpty) {
        await d.update('assets', updates, where: 'id = ?', whereArgs: [id]);
      }
      return id;
    }
    return d.insert('assets', a.toMap()..remove('id'));
  }

  Future<void> updateAssetName(int id, String name) async {
    final d = await database;
    await d.update('assets', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateAssetCategory(int id, String category) async {
    final d = await database;
    await d.update('assets', {'category': category}, where: 'id = ?', whereArgs: [id]);
  }

  /// 设置 / 清除标的的关联 ETF（空串 = 清除）
  Future<void> updateAssetLink(int id, String linkCode) async {
    final d = await database;
    await d.update('assets', {'link_code': linkCode.trim()},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 交易流水 ----------------

  Future<List<Txn>> txns({int? accountId}) async {
    final d = await database;
    final rows = await d.query(
      'txns',
      where: accountId == null ? null : 'account_id = ?',
      whereArgs: accountId == null ? null : [accountId],
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(Txn.fromMap).toList();
  }

  Future<int> saveTxn(Txn t) async {
    final d = await database;
    if (t.id == null) {
      return d.insert('txns', t.toMap()..remove('id'));
    }
    await d.update('txns', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
    return t.id!;
  }

  Future<void> deleteTxn(int id) async {
    final d = await database;
    await d.delete('txns', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 行情缓存 ----------------

  Future<Map<String, Quote>> quotes() async {
    final d = await database;
    final rows = await d.query('quotes');
    return {for (final r in rows) r['code'] as String: Quote.fromMap(r)};
  }

  Future<void> saveQuotes(Iterable<Quote> list) async {
    final d = await database;
    final batch = d.batch();
    for (final q in list) {
      batch.insert('quotes', q.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteQuote(String code) async {
    final d = await database;
    await d.delete('quotes', where: 'code = ?', whereArgs: [code]);
  }

  // ---------------- 目标配置 ----------------

  Future<List<TargetAlloc>> targets() async {
    final d = await database;
    final rows = await d.query('targets', orderBy: 'id ASC');
    return rows.map(TargetAlloc.fromMap).toList();
  }

  Future<void> saveTarget(TargetAlloc t) async {
    final d = await database;
    if (t.id == null) {
      await d.insert('targets', t.toMap()..remove('id'),
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await d.update('targets', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
    }
  }

  Future<void> deleteTarget(int id) async {
    final d = await database;
    await d.delete('targets', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearTargets() async {
    final d = await database;
    await d.delete('targets');
  }

  // ---------------- 宏观估值（股债利差）----------------

  /// 按日期升序读全部历史（画曲线 + 算分位用）
  Future<List<MacroRow>> macroAll() async {
    final d = await database;
    final rows =
        await d.query('macro_history', orderBy: 'date ASC');
    return [
      for (final r in rows)
        MacroRow(
          date: (r['date'] as String?) ?? '',
          hs300Pe: (r['hs300_pe'] as num?)?.toDouble() ?? 0,
          cn10y: (r['cn10y'] as num?)?.toDouble() ?? 0,
          erp: (r['erp'] as num?)?.toDouble() ?? 0,
        ),
    ];
  }

  /// 存一点（同一天覆盖，天然幂等）
  Future<void> saveMacroRow(MacroRow r) async {
    final d = await database;
    await d.insert(
      'macro_history',
      {
        'date': r.date,
        'hs300_pe': r.hs300Pe,
        'cn10y': r.cn10y,
        'erp': r.erp,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------- 设置 ----------------

  Future<String?> setting(String key) async {
    final d = await database;
    final rows = await d.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<double> settingDouble(String key, double fallback) async {
    final v = await setting(key);
    if (v == null) return fallback;
    return double.tryParse(v) ?? fallback;
  }

  Future<void> setSetting(String key, String value) async {
    final d = await database;
    await d.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// 宏观估值的一行（与 `macro_history` 表对应）
///
/// 单独定义而不复用 `MacroPoint`：表里没有"长窗口分位"这一列，
/// 而且 data 层不该依赖网络模型。
class MacroRow {
  final String date;
  final double hs300Pe;
  final double cn10y;
  final double erp;

  const MacroRow({
    required this.date,
    required this.hs300Pe,
    required this.cn10y,
    required this.erp,
  });

  /// 盈利收益率（%）
  double get earningsYield => hs300Pe > 0 ? 100.0 / hs300Pe : 0;
}