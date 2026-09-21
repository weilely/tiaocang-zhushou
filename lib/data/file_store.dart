import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用外部私有目录中的文件读写（Android 上无需任何存储权限）
///
/// - `<外部目录>/export/` 导出的 CSV
/// - `<外部目录>/import/` 放这里面的 CSV 可被导入
///
/// 在 MuMu 模拟器上可用 adb 直接收发文件：
///   adb push 流水.csv /sdcard/Android/data/com.dsh.invest_tracker/files/import/
///   adb pull /sdcard/Android/data/com.dsh.invest_tracker/files/export/ .
class FileStore {
  static Future<Directory> _base() async {
    final d = await getExternalStorageDirectory();
    if (d != null) return d;
    return getApplicationDocumentsDirectory();
  }

  static Future<Directory> _ensure(String name) async {
    final base = await _base();
    final d = Directory(p.join(base.path, name));
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  static Future<Directory> exportDir() => _ensure('export');

  static Future<Directory> importDir() => _ensure('import');

  /// 写入 CSV（带 UTF-8 BOM，Excel 打开中文不乱码）
  static Future<File> writeCsv(Directory dir, String fileName, String content) async {
    final f = File(p.join(dir.path, fileName));
    await f.writeAsString('\uFEFF$content', flush: true);
    return f;
  }

  /// 列出可导入的 CSV（import 与 export 目录）
  static Future<List<File>> listCsv() async {
    final out = <File>[];
    for (final d in [await importDir(), await exportDir()]) {
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.csv')) out.add(e);
      }
    }
    out.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return out;
  }

  static Future<String> readText(File f) => f.readAsString();

  /// 写入 JSON（UTF-8，无 BOM）
  static Future<File> writeJson(Directory dir, String fileName, String content) async {
    final f = File(p.join(dir.path, fileName));
    await f.writeAsString(content, flush: true);
    return f;
  }

  /// 列出可恢复的备份文件（import 与 export 目录下的 .json）
  static Future<List<File>> listBackups() async {
    final out = <File>[];
    for (final d in [await importDir(), await exportDir()]) {
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.json')) out.add(e);
      }
    }
    out.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return out;
  }

  /// 便于展示的目录提示
  static Future<String> hint() async {
    final b = await _base();
    return b.path;
  }
}
