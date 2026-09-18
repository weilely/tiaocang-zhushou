import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqf;

import 'db.dart';
import 'file_store.dart';

/// 单独导出「历史净值」与「基础数据库」两份 SQLite 文件
///
/// 完整 JSON 备份（[backup.dart]）有意**不含**净值历史与行情缓存，
/// 因为体积大、可随时重抓。这里提供「按表拷贝」的独立备份：
/// 把 [AppDatabase] 里的 `nav_history` / `securities` 表整体 dump 成
/// 一个 `.sqlite` 文件，放到 export 目录，便于用 adb 取回或在电脑
/// 里用 sqlite3 查看 / 恢复。
class DbDumper {
  /// 把 [tables]（要导出的表名）连同它们的 schema 一起写进一个独立数据库文件。
  ///
  /// 返回写好的文件路径。
  Future<String> dumpTables({
    required List<String> tables,
    required String fileName,
  }) async {
    final src = await AppDatabase.instance.database;
    final dir = await FileStore.exportDir();
    final target = File(p.join(dir.path, fileName));
    if (target.existsSync()) target.deleteSync();

    final out = await sqf.openDatabase(target.path,
        onConfigure: (_) async {});
    try {
      for (final t in tables) {
        // 1) 照抄源表建表语句
        final sql = await src
            .query('sqlite_master', where: "type='table' AND name='$t'");
        if (sql.isEmpty) continue;
        final createSql = (sql.first['sql'] as String? ?? '').trim();
        if (createSql.isNotEmpty) {
          await out.execute(createSql);
        }
        // 2) 把数据整体拷过来（跨库引用用 sourceDb.name 限定）
        await out.execute('ATTACH ? AS srcdb', [src.path]);
        try {
          await out
              .execute('INSERT OR REPLACE INTO $t SELECT * FROM srcdb.$t');
        } finally {
          await out.execute('DETACH srcdb');
        }
      }
    } finally {
      await out.close();
    }
    return target.path;
  }
}
