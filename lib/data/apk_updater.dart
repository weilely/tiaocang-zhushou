import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用内更新：下载 APK + 交给系统安装器
///
/// 只做「下载 + 拉起安装器」这一半 —— **静默安装做不到**（非系统应用），
/// 系统一定会弹一次「安装」确认。Android 8+ 还要用户先给本应用开
/// 「安装未知应用」，所以先问 [canInstall]，没开就引导去系统设置。
class ApkUpdater {
  static const MethodChannel _ch =
      MethodChannel('com.dsh.invest_tracker/install');

  /// 系统是否允许本应用「安装未知应用」
  static Future<bool> canInstall() async {
    try {
      return await _ch.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到系统的「安装未知应用」设置页
  static Future<void> openInstallSettings() async {
    try {
      await _ch.invokeMethod('openInstallSettings');
    } catch (_) {
      // 打不开就算了，安装时系统也会提示
    }
  }

  /// 把已下载的 APK 交给系统安装器
  static Future<void> install(String path) async {
    await _ch.invokeMethod('installApk', {'path': path});
  }

  /// 下载 APK 到应用外部私有目录（无需任何存储权限），返回文件路径。
  ///
  /// [onProgress] 收到 0..1；[isCancelled] 返回 true 时中止（并删掉半截文件）。
  static Future<String> download(
    String url, {
    required String fileName,
    void Function(double? progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final target = File(p.join(dir.path, fileName));
    if (target.existsSync()) target.deleteSync();

    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) {
        throw Exception('下载失败：HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final sink = target.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.stream) {
          if (isCancelled?.call() ?? false) {
            throw const _Cancelled();
          }
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call(total > 0 ? got / total : null);
        }
      } finally {
        await sink.close();
      }
      if (got == 0) throw Exception('下载内容为空');
      return target.path;
    } catch (e) {
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
  }
}

/// 用户主动取消
class _Cancelled implements Exception {
  const _Cancelled();
}

/// 是不是「被取消」（调用方据此不弹错误）
bool isCancelledError(Object e) => e is _Cancelled;
