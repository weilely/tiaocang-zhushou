import 'package:sqflite/sqflite.dart';

import '../logic/backup.dart';
import 'db.dart';

/// 备份的读写（以扩展方式挂在 [AppDatabase] 上，避免改动既有 DAO）
extension BackupStore on AppDatabase {
  /// 读取全部设置项
  Future<Map<String, String>> allSettings() async {
    final d = await database;
    final rows = await d.query('settings');
    return {
      for (final r in rows) r['key'] as String: (r['value'] as String?) ?? '',
    };
  }

  /// 金融基础数据的**原样表行**（全局备份用）
  Future<List<Map<String, Object?>>> allSecuritiesRows() async {
    final d = await database;
    return await d.query('securities');
  }

  /// 历史净值的**原样表行**（全局备份用；可能几万行）
  Future<List<Map<String, Object?>>> allNavRows() async {
    final d = await database;
    return await d.query('nav_history');
  }

  /// 用备份内容整体替换本地数据（单事务，失败自动回滚）
  Future<void> replaceAllFromBackup(AppBackup b) async {
    final d = await database;
    await d.transaction((txn) async {
      // cash_txns 也要清：它有 src_txn_id 指回 txns，留着旧数据会与
      // 恢复后的交易错位（v1 备份不含现金流水，恢复后现金账本为空）
      await txn.delete('cash_txns');
      // v3：关注列表与定投计划也要清空重写（v2 备份里没有这两张表的数据）
      await txn.delete('watchlist');
      await txn.delete('dca_plans');
      await txn.delete('txns');
      await txn.delete('targets');
      await txn.delete('assets');
      await txn.delete('accounts');
      // 备份里**不含密钥类设置**（见 kSecretSettingKeys），所以先把本机的值
      // 记下来，清表之后再放回去 —— 否则恢复一次 Key 就没了。
      final keepSecrets = <String, String>{};
      for (final k in kSecretSettingKeys) {
        final rows = await txn.query('settings',
            where: 'key = ?', whereArgs: [k], limit: 1);
        if (rows.isNotEmpty) {
          keepSecrets[k] = (rows.first['value'] as String?) ?? '';
        }
      }
      await txn.delete('settings');
      // v4：金融基础数据与历史净值**只在备份里确实带了才覆盖** ——
      // 老备份（v1~v3）这两段是空的，若照清不误会把本地数据白白清掉
      if (b.securities.isNotEmpty) await txn.delete('securities');
      if (b.navHistory.isNotEmpty) await txn.delete('nav_history');

      // 显式写入 id，保持账户 / 标的 / 流水 / 联动现金流水之间的引用关系
      for (final a in b.accounts) {
        if (a.id == null) continue;
        await txn.insert('accounts', a.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final a in b.assets) {
        if (a.id == null) continue;
        await txn.insert('assets', a.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final t in b.txns) {
        if (t.id == null) continue;
        await txn.insert('txns', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final c in b.cashTxns) {
        if (c.id == null) continue;
        await txn.insert('cash_txns', c.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final t in b.targets) {
        if (t.id == null) continue;
        await txn.insert('targets', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final w in b.watchlist) {
        if (w.id == null) continue;
        await txn.insert('watchlist', w.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final p in b.dcaPlans) {
        if (p.id == null) continue;
        await txn.insert('dca_plans', p.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final e in b.settings.entries) {
        await txn.insert('settings', {'key': e.key, 'value': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // 把本机的密钥类设置放回去（备份里刻意没有它们）
      for (final e in keepSecrets.entries) {
        if (e.value.isEmpty) continue;
        await txn.insert('settings', {'key': e.key, 'value': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // 大表分批插：sqflite 的 batch 一次几千行比逐行 await 快得多，
      // 而且历史净值动辄几万行，逐行 insert 会明显卡住恢复
      await _insertRows(txn, 'securities', b.securities);
      await _insertRows(txn, 'nav_history', b.navHistory);
    });
  }

  /// 分批插入原样表行（列名与建表语句一致，直接 insert）
  Future<void> _insertRows(
    Transaction txn,
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    const chunk = 500;
    for (var i = 0; i < rows.length; i += chunk) {
      final end = (i + chunk < rows.length) ? i + chunk : rows.length;
      final batch = txn.batch();
      for (var j = i; j < end; j++) {
        batch.insert(table, rows[j],
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }
  }
}
