import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_info.dart';
import '../core/format.dart';
import '../data/apk_updater.dart';
import '../data/update_source.dart';
import '../state/app_state.dart';

/// 「更新」页面：进来自动查一次，把**更新条目**摊开给用户看
///
/// 以前只有一个弹窗（发现新版本 vX + 两个按钮），新版本更新了什么完全看不到。
/// 现在改成页面：
/// - 顶部：当前版本 / 最新版本 / 来源
/// - 中间：**更新条目** —— 比当前版本新的每一版，逐条列版本号 + 日期 + 发行说明
/// - 底部：能应用内安装就给「下载并安装」，否则给发布页链接（可复制）
///
/// 后台检查（[AppState.checkUpdateInBackground]）已经查过的结果直接拿来显示，
/// 进页面再**强制**查一次（绕过 12 小时节流），保证看到的是最新的。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  @override
  void initState() {
    super.initState();
    // 进页面就强制查一次（用户主动进来，别受后台节流限制）。
    // 放到帧后：build 里要读 AppState，initState 期间不能 depend。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  Future<void> _refresh() async {
    await context.read<AppState>().checkUpdateInBackground(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final res = st.updateCheck;
    final newest = res?.newest;
    final inst = res?.installable;
    final hasNew = st.hasNewVersion;
    // 可安装的那版比当前还新，才算"能用应用内升级"
    final autoTarget =
        (inst != null && isNewerVersion(inst.latest, appVersion)) ? inst : null;
    // 更新条目：比当前版本新的每一版（新→旧）
    final entries = res == null
        ? const <UpdateInfo>[]
        : releasesNewerThan(res.releases, appVersion);

    return Scaffold(
      appBar: AppBar(
        title: const Text('检查更新'),
        actions: [
          IconButton(
            tooltip: '重新检查',
            onPressed: st.checkingUpdate ? null : _refresh,
            icon: st.checkingUpdate
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          _versionCard(context, st, newest, autoTarget, hasNew),
          const SizedBox(height: 10),
          _entriesCard(context, res, entries),
        ],
      ),
    );
  }

  /// 版本对比 + 操作按钮
  ///
  /// [autoTarget] 非空 = 能应用内直接升级（挑中的那版有适配本机 ABI 的包）
  Widget _versionCard(
    BuildContext context,
    AppState st,
    UpdateInfo? newest,
    UpdateInfo? autoTarget,
    bool hasNew,
  ) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    hasNew ? '发现新版本' : '已是最新版本',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                if (st.checkingUpdate)
                  Text('正在检查…',
                      style: TextStyle(fontSize: 11, color: theme.hintColor)),
              ],
            ),
            const SizedBox(height: 10),
            _kv(context, '当前版本', 'v$appVersion'),
            _kv(
              context,
              '最新版本',
              newest == null
                  ? (st.checkingUpdate ? '查询中…' : '查不到')
                  : 'v${newest.latest}（${newest.source}）',
            ),
            // 最新版没包、但更早那版有包时，说清楚"能装的是哪一版"
            if (autoTarget != null &&
                newest != null &&
                autoTarget.latest != newest.latest)
              _kv(context, '可安装版本', 'v${autoTarget.latest}（这一版提供了安装包）'),
            if (newest == null && !st.checkingUpdate) ...[
              const SizedBox(height: 10),
              Text(
                '没能连上代码托管平台（GitHub / Gitee）。\n'
                '常见原因：当前网络访问 GitHub 受限 —— 点右上角可以重新检查，'
                '也可以去 Gitee 镜像仓库手动看最新版本。',
                style: TextStyle(
                    fontSize: 12, color: theme.hintColor, height: 1.6),
              ),
            ],
            const SizedBox(height: 14),
            if (autoTarget != null)
              FilledButton.icon(
                onPressed: () => _downloadAndInstall(autoTarget),
                icon: const Icon(Icons.download, size: 18),
                label: Text('下载并安装 v${autoTarget.latest}'),
              )
            else if (hasNew)
              OutlinedButton.icon(
                onPressed: () => _copyLink(newest?.url ?? ''),
                icon: const Icon(Icons.link, size: 18),
                label: const Text('复制发布页链接'),
              ),
            if (autoTarget != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '新版与当前包同签名，装上直接覆盖、数据不丢（系统会让你确认一次安装）。',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.5),
                ),
              )
            else if (hasNew)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '这一版没有适配你机型的安装包（发布时没上传附件，或只出了别的 CPU '
                  '架构的包），只能手动下载安装。',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.5),
                ),
              ),
            if (hasNew && (newest?.url.isNotEmpty ?? false)) ...[
              const SizedBox(height: 6),
              SelectableText(
                newest!.url,
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 更新条目：比当前版本新的每一版
  Widget _entriesCard(
      BuildContext context, UpdateCheck? res, List<UpdateInfo> entries) {
    final theme = Theme.of(context);
    final title = entries.isEmpty ? '更新条目' : '更新条目（${entries.length} 版）';
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (entries.isEmpty)
              Text(
                res == null
                    ? '还没查到版本信息。'
                    : '当前已是最新版本，没有需要看的更新条目。',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              )
            else
              for (final e in entries) _entryTile(context, e),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(BuildContext context, UpdateInfo e) {
    final theme = Theme.of(context);
    final date = e.publishedAt == null ? '' : fmtDate(e.publishedAt!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('v${e.latest}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              if (date.isNotEmpty)
                Text(date,
                    style: TextStyle(fontSize: 11, color: theme.hintColor)),
              const Spacer(),
              if (e.hasApk)
                Text('有安装包',
                    style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ],
          ),
          const SizedBox(height: 6),
          if (e.hasNotes)
            // 发行说明是纯文本（Markdown 里的 # / - 号原样显示也不难看，
            // 这里不做解析，免得自己写一版不完整的 Markdown 渲染）
            Text(
              e.notes!,
              style: const TextStyle(fontSize: 12, height: 1.7),
            )
          else
            Text('（这一版没有写更新说明）',
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _copyLink(String url) async {
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    _snack('发布页链接已复制');
  }

  /// 下载 APK 并拉起系统安装器
  Future<void> _downloadAndInstall(UpdateInfo info) async {
    // 先确认系统允许本应用「安装未知应用」，没开就引导过去
    if (!await ApkUpdater.canInstall()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要先允许安装'),
          content: const Text(
            'Android 要求手动允许「安装未知应用」，否则下载完也装不上。\n\n'
            '下一步会打开系统设置，请把「调仓助手」这一项打开，再回来重新点「下载并安装」。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true) await ApkUpdater.openInstallSettings();
      return;
    }

    // 上面 await 过 canInstall()：走这条分支说明没进"去设置"，但页面可能已经没了
    if (!mounted) return;

    // 进度用 ValueNotifier 驱动，避免 StatefulBuilder 里轮询刷新的土办法
    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    var dialogOpen = true;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载新版'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 10),
              Text(
                v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '连接中…',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
              dialogOpen = false;
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    String? path;
    Object? err;
    try {
      path = await ApkUpdater.download(
        info.apkUrl!,
        fileName: 'tiaocang-zhushou-v${info.latest}.apk',
        onProgress: (v) => progress.value = v ?? 0,
        isCancelled: () => cancelled,
      );
    } catch (e) {
      err = e;
    }

    // 关掉进度窗（用户点「取消」时它已经关了，别重复 pop）
    if (dialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialog;
    progress.dispose();

    if (cancelled) {
      _snack('已取消下载');
      return;
    }
    if (err != null) {
      _snack(isCancelledError(err) ? '已取消下载' : '下载失败：$err');
      return;
    }
    if (path == null) {
      _snack('下载失败：没有拿到文件');
      return;
    }
    if (!mounted) return;
    try {
      await ApkUpdater.install(path);
      _snack('已交给系统安装器，请按提示确认安装');
    } catch (e) {
      _snack('拉起安装器失败：$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
