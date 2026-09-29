import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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

  // ---------------- 系统文件对话框（SAF，**不需要任何权限**） ----------------

  /// 用系统的「保存到…」把内容存到**用户自己挑的位置**（Downloads / 网盘 / 电脑同步目录都行），
  /// 返回落地位置（取消 → null）。
  ///
  /// 为什么要它（用户 2026-09-29）：「备份、CSV 导出目录可以自定义，不然每次卸载应用
  /// 把备份的数据都删掉了」—— App 私有目录（`Android/data/<包名>/`）在**卸载时会被
  /// 系统一起删掉**，所以导出仍然照写一份（兼容既有流程），同时让他能另存到别处。
  static Future<String?> saveAs(
    String fileName,
    String content, {
    bool bom = false,
  }) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(bom ? '\uFEFF$content' : content)),
        mimeType: fileName.toLowerCase().endsWith('.csv')
            ? 'text/csv'
            : 'application/json',
        dialogTitle: '保存到…',
      );
      return uri == null ? null : _where(uri);
    } catch (_) {
      return null; // 用户取消 / 该机型不支持：调用方按"没另存"处理
    }
  }

  /// 用系统文件选择器挑一个文件读回来（恢复备份 / 导入 CSV 用）。
  /// 返回 `(文件名, 文本)`；取消或读不到 → null。
  static Future<(String, String)?> pickTextFile({
    List<String>? extensions,
  }) async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择文件',
        type: extensions == null ? FileType.any : FileType.custom,
        allowedExtensions: extensions,
      );
      if (picked.isEmpty) return null;
      final f = picked.first;
      // SAF 选的文件可能没有本地路径（content://）→ 退回 xFile 读
      final path = f.path;
      final bytes = path != null
          ? await File(path).readAsBytes()
          : await f.xFile.readAsBytes();
      return (f.name, utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  /// 展示用：把 `content://com.android.providers…` 换成人看得懂的尾段
  static String _where(Uri uri) {
    if (uri.scheme == 'file') return uri.toFilePath();
    final decoded = Uri.decodeComponent(uri.toString());
    final i = decoded.lastIndexOf('/');
    return i < 0 ? decoded : decoded.substring(0, i + 1);
  }
}
