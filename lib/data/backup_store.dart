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

  /// 用备份内容整体替换本地数据（单事务，失败自动回滚）
  Future<void> replaceAllFromBackup(AppBackup b) async {
    final d = await database;
    await d.transaction((txn) async {
      // cash_txns 也要清：它有 src_txn_id 指回 txns，留着旧数据会与
      // 恢复后的交易错位（v1 备份不含现金流水，恢复后现金账本为空）
      await txn.delete('cash_txns');
      await txn.delete('txns');
      await txn.delete('targets');
      await txn.delete('assets');
      await txn.delete('accounts');
      await txn.delete('settings');

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
      for (final e in b.settings.entries) {
        await txn.insert('settings', {'key': e.key, 'value': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
