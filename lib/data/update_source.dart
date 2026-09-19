/// 在线检查最新版本
///
/// 数据源是代码托管平台的公开 API（**只读、不需要 token**）：
/// - GitHub（主仓库）：`/repos/<o>/<r>/releases` 与 `/tags`
/// - Gitee（国内镜像）：同样查 releases 与 tags
///
/// **两边都要查、按版本号取最大**：只发 tag 没建 Release 时，
/// 光看 Release 会把「最新版本」显示成上一个旧版本（实测 v1.0.1 只有 tag，
/// 界面因此显示成 v1.0.0）。
///
/// 顺带把 Release 里的 **APK 附件直链**捞出来（[UpdateInfo.apkUrl]），
/// 有附件就能在应用内直接下载安装；没附件则如实提示「只能手动下载」。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// 查到的版本信息
class UpdateInfo {
  /// 最新版本号（已去掉前缀 v，形如 `1.0.2`）
  final String latest;

  /// 建议打开的页面（Release 页，退化为仓库页）
  final String url;

  /// 来源（'GitHub' / 'Gitee'），用于在界面上说明
  final String source;

  /// 该版本 APK 附件的**直链**；仓库里没传附件时为 null
  final String? apkUrl;

  const UpdateInfo({
    required this.latest,
    required this.url,
    required this.source,
    this.apkUrl,
  });

  /// 能不能在应用内直接下载安装
  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;
}

/// 把 `v1.0.2` / `1.0.2` / `release-1.0.2` 这类串解析成 `[1,0,2]`
List<int>? parseVersion(String raw) {
  final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
  if (m == null) return null;
  return [
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  ];
}

/// [a] 是否比 [b] 新（都按 X.Y.Z 比；无法解析时返回 false）
bool isNewerVersion(String a, String b) {
  final va = parseVersion(a);
  final vb = parseVersion(b);
  if (va == null || vb == null) return false;
  for (var i = 0; i < 3; i++) {
    if (va[i] != vb[i]) return va[i] > vb[i];
  }
  return false;
}

/// 从一串 tag 名里挑出最大的版本号（规范化成 `X.Y.Z`）
String? pickNewest(List<String> tags) {
  String? best;
  for (final t in tags) {
    final v = parseVersion(t);
    if (v == null) continue;
    if (best == null || isNewerVersion(t, best)) {
      best = '${v[0]}.${v[1]}.${v[2]}';
    }
  }
  return best;
}

/// 各仓库地址（改这里即可切换 / 增加镜像源）
class UpdateSource {
  /// GitHub 主仓库
  static const String githubRepo = 'weilely/tiaocang-zhushou';

  /// Gitee 镜像仓库（国内访问更稳；GitHub 查不到时自动落到这里）
  static const String giteeRepo = 'weilely/tiaocang-zhushou';
}

/// 查最新版本；全都失败返回 null（调用方按「查不到」提示，不报错）
Future<UpdateInfo?> fetchLatestVersion({
  String githubRepo = UpdateSource.githubRepo,
  String giteeRepo = UpdateSource.giteeRepo,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final tries = <Future<UpdateInfo?> Function()>[
    () => _github(githubRepo, timeout),
    () => _gitee(giteeRepo, timeout),
  ];
  for (final t in tries) {
    try {
      final r = await t();
      if (r != null) return r;
    } catch (_) {
      // 换下一个源
    }
  }
  return null;
}

// ==================== GitHub ====================

Future<UpdateInfo?> _github(String repo, Duration timeout) async {
  if (repo.isEmpty) return null;
  const headers = {'Accept': 'application/vnd.github+json'};
  final found = <UpdateInfo>[];

  // ① releases 列表（不用 releases/latest：要顺便把 APK 附件直链捞出来）
  try {
    final rel = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases?per_page=30'),
      headers: headers,
    ).timeout(timeout);
    if (rel.statusCode == 200) {
      final list = jsonDecode(rel.body);
      if (list is List) {
        for (final m in list) {
          if (m is! Map) continue;
          final v = parseVersion((m['tag_name'] ?? '').toString());
          if (v == null) continue;
          final page = (m['html_url'] ?? '').toString();
          found.add(UpdateInfo(
            latest: '${v[0]}.${v[1]}.${v[2]}',
            url: page.isNotEmpty ? page : 'https://github.com/$repo/releases',
            source: 'GitHub',
            apkUrl: _apkAssetOf(m['assets']),
          ));
        }
      }
    }
  } catch (_) {
    // 忽略，继续试 tags
  }

  // ② tags —— 必须也查（见文件头注释）
  try {
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/tags?per_page=100'),
      headers: headers,
    ).timeout(timeout);
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body);
      if (list is List) {
        for (final e in list) {
          if (e is! Map || e['name'] == null) continue;
          final v = parseVersion(e['name'].toString());
          if (v == null) continue;
          found.add(UpdateInfo(
            latest: '${v[0]}.${v[1]}.${v[2]}',
            url: 'https://github.com/$repo/releases',
            source: 'GitHub',
          ));
        }
      }
    }
  } catch (_) {
    // 忽略
  }

  return _newestOf(found);
}

// ==================== Gitee ====================

Future<UpdateInfo?> _gitee(String repo, Duration timeout) async {
  if (repo.isEmpty) return null;
  final found = <UpdateInfo>[];

  // Gitee 的 releases 列表（`releases/latest` 在没建发行版时会 404）
  try {
    final rel = await http.get(
      Uri.parse('https://gitee.com/api/v5/repos/$repo/releases?per_page=30'),
    ).timeout(timeout);
    if (rel.statusCode == 200) {
      final list = jsonDecode(rel.body);
      if (list is List) {
        for (final m in list) {
          if (m is! Map) continue;
          final v = parseVersion((m['tag_name'] ?? '').toString());
          if (v == null) continue;
          found.add(UpdateInfo(
            latest: '${v[0]}.${v[1]}.${v[2]}',
            url: 'https://gitee.com/$repo/releases',
            source: 'Gitee',
            apkUrl: _giteeApkOf(m),
          ));
        }
      }
    }
  } catch (_) {
    // 忽略
  }

  try {
    final res = await http.get(
      Uri.parse('https://gitee.com/api/v5/repos/$repo/tags?per_page=100'),
    ).timeout(timeout);
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body);
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          final raw = (e['name'] ?? e['tag_name'])?.toString();
          if (raw == null) continue;
          final v = parseVersion(raw);
          if (v == null) continue;
          found.add(UpdateInfo(
            latest: '${v[0]}.${v[1]}.${v[2]}',
            url: 'https://gitee.com/$repo/releases',
            source: 'Gitee',
          ));
        }
      }
    }
  } catch (_) {
    // 忽略
  }

  return _newestOf(found);
}

// ==================== 公共小件 ====================

/// 从 release 的 assets 里挑出 APK 附件的下载直链
///
/// 优先 `application/vnd.android.package-archive`，退而按文件名 `.apk` 判断。
String? _apkAssetOf(Object? assets) {
  if (assets is! List) return null;
  String? byMime;
  String? byName;
  for (final a in assets) {
    if (a is! Map) continue;
    final url = (a['browser_download_url'] ?? '').toString();
    if (url.isEmpty) continue;
    final type = (a['content_type'] ?? '').toString();
    final name = (a['name'] ?? '').toString().toLowerCase();
    if (type.contains('android.package-archive')) byMime ??= url;
    if (name.endsWith('.apk')) byName ??= url;
  }
  return byMime ?? byName;
}

/// Gitee 发行版的附件：主字段是 `assets`（与 GitHub 同名），
/// 退一步兼容 `attach_files`（Gitee 网页上传的附件走这个）
String? _giteeApkOf(Map m) {
  final byAssets = _apkAssetOf(m['assets']);
  if (byAssets != null) return byAssets;
  final files = m['attach_files'];
  if (files is List) {
    for (final f in files) {
      if (f is! Map) continue;
      final url =
          (f['browser_download_url'] ?? f['download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      final name = (f['name'] ?? f['title'] ?? '').toString().toLowerCase();
      if (name.endsWith('.apk') || url.toLowerCase().contains('.apk')) return url;
    }
  }
  return null;
}

/// 从多个候选里取版本号最大的那个；**版本相同时优先带 APK 附件的**
/// （否则会把「能直接下载安装」的能力丢掉）
UpdateInfo? _newestOf(List<UpdateInfo> list) {
  UpdateInfo? best;
  for (final e in list) {
    if (best == null) {
      best = e;
      continue;
    }
    if (isNewerVersion(e.latest, best.latest)) {
      best = e;
    } else if (e.latest == best.latest && e.hasApk && !best.hasApk) {
      best = e;
    }
  }
  return best;
}
