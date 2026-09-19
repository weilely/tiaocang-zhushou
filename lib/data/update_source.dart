/// 在线检查最新版本
///
/// 数据源是代码托管平台的公开 API（**只读、不需要 token**）：
/// - GitHub（当前主仓库）：`/repos/<owner>/<repo>/releases/latest`，没发 Release 就退到 `/tags`
/// - Gitee（国内镜像）：同样优先 releases、退到 tags
///
/// 只做「查」不做「装」：拿到新版号后把下载页交给用户自己点，
/// 不静默下载安装包 —— 那属于拿用户设备开玩笑。
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

  const UpdateInfo({
    required this.latest,
    required this.url,
    required this.source,
  });
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

/// 从一串 tag 名里挑出最大的版本号
String? pickNewest(List<String> tags) {
  String? best;
  for (final t in tags) {
    if (parseVersion(t) == null) continue;
    if (best == null || isNewerVersion(t, best)) best = t;
  }
  if (best == null) return null;
  final v = parseVersion(best)!;
  return '${v[0]}.${v[1]}.${v[2]}';
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

Future<UpdateInfo?> _github(String repo, Duration timeout) async {
  if (repo.isEmpty) return null;
  const headers = {'Accept': 'application/vnd.github+json'};
  final found = <UpdateInfo>[];

  // ① releases/latest
  try {
    final rel = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: headers,
    ).timeout(timeout);
    if (rel.statusCode == 200) {
      final m = jsonDecode(rel.body);
      final tag = (m is Map ? m['tag_name'] : null)?.toString() ?? '';
      final v = parseVersion(tag);
      if (v != null) {
        final page = (m['html_url'] ?? '').toString();
        found.add(UpdateInfo(
          latest: '${v[0]}.${v[1]}.${v[2]}',
          url: page.isNotEmpty ? page : 'https://github.com/$repo/releases',
          source: 'GitHub',
        ));
      }
    }
  } catch (_) {
    // 忽略，继续试 tags
  }

  // ② tags —— **必须也查**：发了新 tag 但还没建 Release 时，
  //    releases/latest 会返回上一个旧版本（实测 v1.0.1 只有 tag，
  //    界面因此把「最新版本」显示成 v1.0.0）。
  try {
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/tags?per_page=100'),
      headers: headers,
    ).timeout(timeout);
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body);
      if (list is List) {
        final newest = pickNewest([
          for (final e in list)
            if (e is Map && e['name'] != null) e['name'].toString(),
        ]);
        if (newest != null) {
          found.add(UpdateInfo(
            latest: newest,
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

/// 从多个候选里取版本号最大的那个
UpdateInfo? _newestOf(List<UpdateInfo> list) {
  UpdateInfo? best;
  for (final e in list) {
    if (best == null || isNewerVersion(e.latest, best.latest)) best = e;
  }
  return best;
}

Future<UpdateInfo?> _gitee(String repo, Duration timeout) async {
  if (repo.isEmpty) return null;
  final found = <UpdateInfo>[];

  try {
    final rel = await http.get(
      Uri.parse('https://gitee.com/api/v5/repos/$repo/releases/latest'),
    ).timeout(timeout);
    if (rel.statusCode == 200) {
      final m = jsonDecode(rel.body);
      final tag = (m is Map ? m['tag_name'] : null)?.toString() ?? '';
      final v = parseVersion(tag);
      if (v != null) {
        found.add(UpdateInfo(
          latest: '${v[0]}.${v[1]}.${v[2]}',
          url: 'https://gitee.com/$repo/releases',
          source: 'Gitee',
        ));
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
        final newest = pickNewest([
          for (final e in list)
            if (e is Map && (e['name'] ?? e['tag_name']) != null)
              (e['name'] ?? e['tag_name']).toString(),
        ]);
        if (newest != null) {
          found.add(UpdateInfo(
            latest: newest,
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
