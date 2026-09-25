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

  /// 发行说明（Release 的 body）；只发了 tag、没建发行版时为 null
  final String? notes;

  /// 发行时间（Release 的 published_at / created_at 解析而来）；解析不出来为 null
  final DateTime? publishedAt;

  const UpdateInfo({
    required this.latest,
    required this.url,
    required this.source,
    this.apkUrl,
    this.notes,
    this.publishedAt,
  });

  /// 能不能在应用内直接下载安装
  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;

  /// 有没有可显示的更新条目
  bool get hasNotes => notes != null && notes!.trim().isNotEmpty;
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

/// 一次检查的结果
typedef UpdateCheck = ({
  /// 最新版本（可能没提供安装包）
  UpdateInfo newest,

  /// 最新**带可用安装包**的版本（可能比 [newest] 旧，也可能相等、也可能没有）
  UpdateInfo? installable,

  /// 查到过的**所有发行条目**（新→旧，同版本去重）—— 更新页面用它列「更新条目」
  List<UpdateInfo> releases,
});

/// 查最新版本；全都失败返回 null（调用方按「查不到」提示，不报错）
///
/// [deviceAbi] 传设备主 ABI（如 `arm64-v8a`）：拆分打包后发行版里有多个
/// 架构的 APK，按它挑对应那个；空串则优先"不带架构后缀"的通用包。
///
/// **两个源都查、合并后再取最新**，而不是"先问 GitHub、拿到就返回"：
/// GitHub 上常常只有 tag 没有附件，若它先返回就会把 Gitee 上**带附件**的
/// 同一版本盖掉 —— 应用内更新明明能用，却退化成"只能手动下载"。
///
/// 返回 [UpdateCheck]：除了最新版本，还挑出**最新那个带安装包的版本**，
/// 以及**所有发行条目**（含发行说明，供更新页面展示「更新条目」）。
/// 因为发布策略是"只在值得的版本传附件"，最新版很可能没附件，
/// 这时能直接安装的往往是更早的那一版 —— 界面上要能把它指出来，
/// 否则应用内更新只在刚发完包的那阵子可用。
Future<UpdateCheck?> checkUpdate({
  String githubRepo = UpdateSource.githubRepo,
  String giteeRepo = UpdateSource.giteeRepo,
  String deviceAbi = '',
  Duration timeout = const Duration(seconds: 12),
}) async {
  final all = <UpdateInfo>[];
  for (final t in <Future<List<UpdateInfo>> Function()>[
    () => _github(githubRepo, timeout, deviceAbi),
    () => _gitee(giteeRepo, timeout, deviceAbi),
  ]) {
    try {
      all.addAll(await t());
    } catch (_) {
      // 这个源不可用，换下一个
    }
  }
  final newest = _newestOf(all);
  if (newest == null) return null;
  final installable = _newestOf([
    for (final e in all)
      if (e.hasApk) e,
  ]);
  return (newest: newest, installable: installable, releases: mergeReleases(all));
}

/// 把多个源查到的条目按版本号合并去重，**新→旧**排序
///
/// 同一版本两个源都有时（GitHub 有 tag、Gitee 建了发行版带说明），
/// 留「信息更全」的那条：先看有没有发行说明，再看有没有安装包 ——
/// 否则更新条目里会出现两行同一个版本、或者有说明的那条被没说明的盖掉。
List<UpdateInfo> mergeReleases(List<UpdateInfo> all) {
  final byVersion = <String, UpdateInfo>{};
  for (final e in all) {
    final old = byVersion[e.latest];
    byVersion[e.latest] = old == null ? e : _richer(old, e);
  }
  final list = byVersion.values.toList();
  list.sort((a, b) {
    if (isNewerVersion(a.latest, b.latest)) return -1; // 更新的排前面
    if (isNewerVersion(b.latest, a.latest)) return 1;
    return 0;
  });
  return list;
}

/// 同版本两条记录里留哪条：有发行说明的优先，其次有安装包的
UpdateInfo _richer(UpdateInfo a, UpdateInfo b) {
  if (a.hasNotes != b.hasNotes) return a.hasNotes ? a : b;
  if (a.hasApk != b.hasApk) return a.hasApk ? a : b;
  return a;
}

/// 比 [current] 新的那些发行条目（保持新→旧顺序）—— 更新页面显示这些
List<UpdateInfo> releasesNewerThan(List<UpdateInfo> releases, String current) =>
    [
      for (final e in releases)
        if (isNewerVersion(e.latest, current)) e,
    ];

/// 只要最新版本号（老调用点用；不需要「可安装版本」时用这个）
Future<UpdateInfo?> fetchLatestVersion({
  String githubRepo = UpdateSource.githubRepo,
  String giteeRepo = UpdateSource.giteeRepo,
  String deviceAbi = '',
  Duration timeout = const Duration(seconds: 12),
}) async {
  final r = await checkUpdate(
    githubRepo: githubRepo,
    giteeRepo: giteeRepo,
    deviceAbi: deviceAbi,
    timeout: timeout,
  );
  return r?.newest;
}

// ==================== GitHub ====================

/// 把一个 GitHub Release（JSON map）解析成 [UpdateInfo]（纯函数，便于单测）
///
/// 解析不出合法版本号 → null（不带版本号的 release 直接跳过）。
UpdateInfo? githubReleaseToInfo(Map m, String repo, String abi) {
  final v = parseVersion((m['tag_name'] ?? '').toString());
  if (v == null) return null;
  final page = (m['html_url'] ?? '').toString();
  return UpdateInfo(
    latest: '${v[0]}.${v[1]}.${v[2]}',
    url: page.isNotEmpty ? page : 'https://github.com/$repo/releases',
    source: 'GitHub',
    apkUrl: pickApkAssetForAbi(m['assets'], abi),
    notes: _notesOf(m),
    publishedAt: _dateOf(m),
  );
}

/// 把一个 Gitee Release（JSON map）解析成 [UpdateInfo]（纯函数，便于单测）
UpdateInfo? giteeReleaseToInfo(Map m, String repo, String abi) {
  final v = parseVersion((m['tag_name'] ?? '').toString());
  if (v == null) return null;
  return UpdateInfo(
    latest: '${v[0]}.${v[1]}.${v[2]}',
    url: 'https://gitee.com/$repo/releases',
    source: 'Gitee',
    apkUrl: _giteeApkOf(m, abi),
    notes: _notesOf(m),
    publishedAt: _dateOf(m),
  );
}

/// tag 条目（tags 接口只有名字，没有发行说明/时间）
UpdateInfo? tagToInfo(String rawTag, {required String url, required String source}) {
  final v = parseVersion(rawTag);
  if (v == null) return null;
  return UpdateInfo(
    latest: '${v[0]}.${v[1]}.${v[2]}',
    url: url,
    source: source,
  );
}

/// Release 里的发行说明文字（GitHub 与 Gitee 都叫 `body`）
String? _notesOf(Map m) {
  final raw = (m['body'] ?? m['description'] ?? '').toString().trim();
  return raw.isEmpty ? null : raw;
}

/// Release 的发行时间：优先 `published_at`，退回 `created_at`
DateTime? _dateOf(Map m) {
  for (final k in const ['published_at', 'created_at']) {
    final s = (m[k] ?? '').toString().trim();
    if (s.isEmpty) continue;
    final d = DateTime.tryParse(s);
    if (d != null) return d.toLocal();
  }
  return null;
}

Future<List<UpdateInfo>> _github(String repo, Duration timeout, String abi) async {
  if (repo.isEmpty) return const [];
  const headers = {'Accept': 'application/vnd.github+json'};
  final found = <UpdateInfo>[];

  // ① releases 列表（不用 releases/latest：要顺便把发行说明与 APK 附件直链捞出来）
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
          final info = githubReleaseToInfo(m, repo, abi);
          if (info != null) found.add(info);
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
          final info = tagToInfo(
            e['name'].toString(),
            url: 'https://github.com/$repo/releases',
            source: 'GitHub',
          );
          if (info != null) found.add(info);
        }
      }
    }
  } catch (_) {
    // 忽略
  }

  return found;
}

// ==================== Gitee ====================

Future<List<UpdateInfo>> _gitee(String repo, Duration timeout, String abi) async {
  if (repo.isEmpty) return const [];
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
          final info = giteeReleaseToInfo(m, repo, abi);
          if (info != null) found.add(info);
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
          final info = tagToInfo(
            raw,
            url: 'https://gitee.com/$repo/releases',
            source: 'Gitee',
          );
          if (info != null) found.add(info);
        }
      }
    }
  } catch (_) {
    // 忽略
  }

  return found;
}

// ==================== 公共小件 ====================

/// ABI 在附件名里的匹配片段
///
/// 拆分打包的附件名形如 `tiaocang-zhushou-v1.0.4-arm64.apk` /
/// `...-armeabi-v7a.apk` / `...-x86_64.apk`。
/// 注意顺序：`arm64` 不能匹配到 `armeabi-v7a`。
List<String> _abiTokens(String abi) {
  final a = abi.toLowerCase();
  if (a.startsWith('arm64')) return const ['arm64'];
  if (a.startsWith('armeabi-v7a')) return const ['armeabi-v7a'];
  if (a.startsWith('armeabi')) return const ['armeabi'];
  if (a.startsWith('x86_64')) return const ['x86_64'];
  if (a.startsWith('x86')) return const ['x86'];
  return const [];
}

/// 附件名里出现过的所有架构片段（用来判断"这是拆分包还是通用包"）
const List<String> _allAbiTokens = [
  'arm64',
  'armeabi-v7a',
  'armeabi',
  'x86_64',
  'x86',
];

/// 从 release 的 assets 里挑出 APK 附件的下载直链
///
/// 优先级：**匹配设备 ABI 的拆分包** → 不带架构后缀的通用包 → **null**。
///
/// 注意最后是 null 而不是"随便挑一个 .apk"：如果发行版里**全是**带架构的包、
/// 却没有一个是本机架构的，那说明这个版本没给本机出包 —— 硬塞一个别的架构
/// 只会下载成功、安装失败，不如如实说"没有适配你机型的包"。
String? pickApkAssetForAbi(Object? assets, String abi) {
  if (assets is! List) return null;
  final wanted = _abiTokens(abi);

  String? byAbi; // 命中设备架构
  String? byGeneric; // 名字里不带任何架构 → 通用包

  for (final a in assets) {
    if (a is! Map) continue;
    final url = (a['browser_download_url'] ?? '').toString();
    if (url.isEmpty) continue;
    final name = (a['name'] ?? '').toString().toLowerCase();
    if (!name.endsWith('.apk')) continue;

    if (wanted.isNotEmpty && wanted.any(name.contains)) {
      byAbi ??= url;
      continue;
    }
    if (!_allAbiTokens.any(name.contains)) byGeneric ??= url;
  }
  return byAbi ?? byGeneric;
}

/// Gitee 发行版的附件：主字段是 `assets`（与 GitHub 同名），
/// 退一步兼容 `attach_files`（Gitee 网页上传的附件走这个）
String? _giteeApkOf(Map m, String abi) {
  final byAssets = pickApkAssetForAbi(m['assets'], abi);
  if (byAssets != null) return byAssets;
  final files = m['attach_files'];
  if (files is List) {
    // 归一成 assets 的形状，复用同一套「按 ABI 挑」的逻辑
    final normalized = <Map<String, Object?>>[
      for (final f in files)
        if (f is Map)
          {
            'name': f['name'] ?? f['title'] ?? '',
            'browser_download_url':
                f['browser_download_url'] ?? f['download_url'] ?? '',
          },
    ];
    return pickApkAssetForAbi(normalized, abi);
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
