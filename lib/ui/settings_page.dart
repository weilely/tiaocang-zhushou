import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_info.dart';
import '../core/format.dart';
import '../data/apk_updater.dart';
import '../data/file_store.dart';
import '../data/update_source.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
import '../logic/backup.dart';
import '../state/app_state.dart';
import 'all_txns_page.dart';
import 'widgets/common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;

  /// 正在联网检查更新
  bool _checkingUpdate = false;

  /// 调仓目标：标的代码 → 目标占比输入框
  final Map<String, TextEditingController> _targetCtrl = {};

  /// 行情指标筹码的 key（按下拉菜单要对着它弹）
  final Map<String, GlobalKey> _chipKeys = {};

  @override
  void initState() {
    super.initState();
    // 基础数据库的条数只在启动时算过一次，之后搜一次就多缓存几条 ——
    // 进设置页重新算一遍，免得显示"基金 31 条"而库里其实有 69 条
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().loadSecuritiesStats();
    });
  }

  @override
  void dispose() {
    for (final c in _targetCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _targetCtrlFor(String code, double ratio) {
    return _targetCtrl.putIfAbsent(
      code,
      () => TextEditingController(text: ratio <= 0 ? '' : _pctText(ratio)),
    );
  }

  static String _pctText(double ratio) {
    var s = (ratio * 100).toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// 「同花顺数据源」API Key 输入框（值由 AppState 持久化，这里只做展示）
  final _hithinkKeyCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();

    // 设置已是底部第 5 个页签，标题栏由外壳提供，所以这里不再自带 Scaffold/AppBar。
    // 忙碌进度条内联到列表顶部，保留「正在处理」的反馈。
    return ListView(
      // 同上：不要和别的页签共用 PrimaryScrollController
      primary: false,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _accountSection(context, st),
        _targetSection(context, st),
        _dataSection(context, st),
        _marketSection(context, st),
        _hithinkSection(context, st),
          _securitySection(context, st),
        _appearanceSection(context, st),
        _aboutSection(context),
      ],
    );
  }

  // ---------------- 账户 ----------------

  Widget _accountSection(BuildContext context, AppState st) {
    return CollapsibleSectionCard(
      title: '账户管理（${st.accounts.length}）',
      // 默认展开：加账户 / 改备注是常用操作
      initiallyExpanded: true,
      child: Column(
        children: [
          for (final a in st.accounts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.account_balance_wallet_outlined, size: 20),
              title: Text(a.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                a.note.isEmpty ? '暂无备注' : a.note,
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) {
                  if (v == 'rename') _editAccount(a);
                  if (v == 'delete') _deleteAccount(a);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          // 「新增」放到卡片**里面**（用户要求）——原先挂在卡片标题行右侧，看着像卡片外的操作
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.add_circle_outline, size: 20),
            title: const Text('新增账户', style: TextStyle(fontSize: 14)),
            onTap: _addAccount,
          ),
        ],
      ),
    );
  }

  Future<void> _addAccount() async {
    final nameC = TextEditingController();
    final noteC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameC,
                autofocus: true,
                decoration: const InputDecoration(labelText: '账户名称')),
            const SizedBox(height: 12),
            TextField(
                controller: noteC,
                decoration: const InputDecoration(labelText: '备注（可选）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().addAccount(nameC.text, noteC.text);
  }

  Future<void> _editAccount(Account a) async {
    final nameC = TextEditingController(text: a.name);
    final noteC = TextEditingController(text: a.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: '账户名称')),
            const SizedBox(height: 12),
            TextField(
                controller: noteC,
                decoration: const InputDecoration(labelText: '备注')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().updateAccount(
          a.copyWith(name: nameC.text.trim(), note: noteC.text.trim()),
        );
  }

  Future<void> _deleteAccount(Account a) async {
    final count = context
        .read<AppState>()
        .txns
        .where((t) => t.accountId == a.id)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除账户「${a.name}」？'),
        content: Text(count > 0
            ? '该账户下有 $count 笔交易记录，删除后一并移除，且无法恢复。'
            : '该账户下没有交易记录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD93A3A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().removeAccount(a.id!);
  }

  // ---------------- 调仓目标 ----------------

  /// 按**具体标的**设目标占比（调仓页的「调仓方案」就按它算买卖金额）
  ///
  /// 只列**当前还有份额**的标的：已经清仓的不需要再给它定目标比例。
  /// 卡片默认收起，免得一屏全是基金行。
  Widget _targetSection(BuildContext context, AppState st) {
    final held = <Asset>{
      for (final p in st.allPositions)
        if (!p.isEmpty) p.asset,
    }.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);

    if (held.isEmpty) {
      return CollapsibleSectionCard(
        title: '调仓目标',
        initiallyExpanded: false,
        child: Text('当前没有持仓标的', style: TextStyle(fontSize: 13, color: hint.color)),
      );
    }

    for (final a in held) {
      final ratio = st.targets
          .where((t) => t.key == TargetAlloc.assetKey(a.code))
          .fold<double>(0, (acc, t) => acc + t.ratio);
      _targetCtrlFor(a.code, ratio);
    }

    final sum = _targetCtrl.values
        .fold<double>(0, (acc, c) => acc + (double.tryParse(c.text.trim()) ?? 0));

    return CollapsibleSectionCard(
      title: '调仓目标（${held.length} 只）',
      initiallyExpanded: false,
      trailing: TextButton.icon(
        onPressed: () => _fillByCurrent(st, held),
        icon: const Icon(Icons.auto_fix_high, size: 18),
        label: const Text('按当前占比'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('给每只基金 / 股票填目标占比，调仓页按它算需买入 / 需卖出的金额；'
              '留空的标的按「保持现状」处理，不参与买卖建议。', style: hint),
          const SizedBox(height: 6),
          for (final a in held)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.name.isEmpty ? a.code : a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14)),
                        Text('${a.code} · ${a.kind.label}', style: hint),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _targetCtrl[a.code],
                      textAlign: TextAlign.right,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(suffixText: '%', isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 22),
          Row(
            children: [
              Text('目标合计：', style: hint),
              Text(
                '${sum.toStringAsFixed(2)}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: sum > 100.001
                      ? const Color(0xFFD93A3A)
                      : (sum - 100).abs() < 0.01
                          ? const Color(0xFF1A9C5B)
                          : Theme.of(context).hintColor,
                ),
              ),
              if (sum > 100.001)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text('超过 100%', style: hint.copyWith(color: const Color(0xFFD93A3A))),
                ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _saveTargets,
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 按当前市值占比一键填充（省得手填一遍）
  void _fillByCurrent(AppState st, List<Asset> held) {
    final total = st.summary.marketValue;
    if (total <= 0) return;
    final byCode = {
      for (final s in st.assetAllocation) s.key.replaceFirst('asset:', ''): s.value,
    };
    setState(() {
      for (final a in held) {
        final v = byCode[a.code] ?? 0;
        _targetCtrl[a.code]?.text = _pctText(v / total);
      }
    });
  }

  Future<void> _saveTargets() async {
    final st = context.read<AppState>();
    final names = {for (final a in st.assetList) a.code: a};
    for (final e in _targetCtrl.entries) {
      final pct = double.tryParse(e.value.text.trim()) ?? 0;
      final name = names[e.key];
      if (pct <= 0) {
        await st.removeTarget(TargetAlloc.assetKey(e.key));
      } else {
        await st.setTargetRatio(
          TargetAlloc.assetKey(e.key),
          name == null || name.name.isEmpty ? e.key : name.name,
          (pct / 100).clamp(0.0, 1.0),
        );
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('调仓目标已保存'), duration: Duration(seconds: 1)),
    );
  }

  // ---------------- 数据导入导出 ----------------

  /// 重建历史净值（修净值日期错位）
  Future<void> _confirmRebuildNav(AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重建历史净值？'),
        content: const Text(
          '会把本地已保存的历史净值全部删掉，再按北京时间重新抓一遍。\n\n'
          '用在净值日期整体错位的时候：手机时区不是北京时间（例如出国改成 UTC+0）时，'
          '老版本会把日期写成前一天，日历图就会「周五空着、周日反倒有收益」。\n\n'
          '需要联网，标的越多越慢，中途可以关掉页面。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始重建')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await st.rebuildNavHistory();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(n > 0 ? '已重建 $n 条历史净值' : '没抓到净值数据，请检查网络'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _dataSection(BuildContext context, AppState st) {
    final lastBackup = st.lastBackupAt == null
        ? '尚未备份过'
        : '上次备份 ${fmtDateTime(st.lastBackupAt!)}';
    final lastSec = st.securitiesUpdatedAt == null
        ? '尚未更新过'
        : '上次更新 ${fmtDateTime(st.securitiesUpdatedAt!)}';

    return CollapsibleSectionCard(
      title: '数据维护中心',
      // 默认展开：这里是常用入口（全部交易 / 备份 / 重建净值）
      initiallyExpanded: true,
      showCollapseAtBottom: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 持仓页按设计稿改成纯卡片列表后，这里就是「全部交易」的唯一入口
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.receipt_long_outlined, size: 20),
            title: const Text('全部交易', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '共 ${st.txns.length} 笔，含已清仓的标的',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AllTxnsPage()),
            ),
          ),
          const Divider(height: 16),
          _groupHeader(context, '历史净值'),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '库内 ${st.navRowCount} 条 · ${st.navUpdatedAt == null ? '尚未更新过' : '上次更新 ${fmtDateTime(st.navUpdatedAt!)}'}',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            enabled: !st.navUpdating,
            leading: const Icon(Icons.restore_page_outlined, size: 20),
            title: const Text('重建历史净值', style: TextStyle(fontSize: 14)),
            trailing: st.navUpdating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right, size: 20),
            onTap: () => _confirmRebuildNav(st),
          ),
          if (st.navUpdating)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('重建中 ${st.navProgress}',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor)),
            ),
          const Divider(height: 16),
          _groupHeader(context, '基础数据库'),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '基金 ${st.securitiesFundCount} 条 · 股票 ${st.securitiesStockCount} 条 · $lastSec',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
            ),
          ),
          if (st.securitiesBusy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      st.securitiesProgress.isEmpty ? '更新中…' : st.securitiesProgress,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            enabled: !st.securitiesBusy,
            leading: const Icon(Icons.menu_book_outlined, size: 20),
            title: const Text('更新金融基础数据', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '基金 ${st.securitiesFundCount} 条 · 股票 ${st.securitiesStockCount} 条',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: () => _updateSecurities(st),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            enabled: !st.securitiesBusy,
            leading: const Icon(Icons.delete_sweep_outlined, size: 20),
            title: const Text('清空基础数据库', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '只清基础数据库，不影响持仓与流水',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: () => _clearSecurities(st),
          ),
          const Divider(height: 22),
          _groupHeader(context, '备份与恢复'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.shield_outlined, size: 20),
            title: const Text('导出全局备份', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '持仓与流水、关注与定投、金融基础数据（${st.securitiesFundCount + st.securitiesStockCount} 条）、'
              '历史净值（${st.navRowCount} 条）全都包含',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: _exportBackup,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.restore_outlined, size: 20),
            title: const Text('从备份恢复', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              lastBackup,
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: _restoreBackup,
          ),
          const Divider(height: 22),
          _groupHeader(context, '导入导出'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.upload_file_outlined, size: 20),
            title: const Text('导出交易流水 CSV', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '共 ${st.txns.length} 笔，便于在 Excel 里查看',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: () => _export(
              '流水_${_stamp()}.csv',
              st.exportTxns(),
              '交易流水',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.table_chart_outlined, size: 20),
            title: const Text('导出持仓报表 CSV', style: TextStyle(fontSize: 14)),
            onTap: () => _export(
              '持仓_${_stamp()}.csv',
              st.exportPositions(),
              '持仓报表',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.download_outlined, size: 20),
            title: const Text('从 CSV 导入交易流水', style: TextStyle(fontSize: 14)),
            onTap: _import,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.folder_open_outlined, size: 20),
            title: const Text('查看数据目录', style: TextStyle(fontSize: 14)),
            onTap: _showDirs,
          ),
        ],
      ),
    );
  }

  /// 「同花顺数据源」：行情第三路备用源，需填 API Key 才启用；不填不影响东财/新浪。
  Widget _hithinkSection(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    // 首次构建把库里存的 Key 回填进输入框（obscure，不明文回显）。
    // 只在**输入框为空**时回填：否则边打字边回填会把光标顶回开头。
    final currentKey = st.hithinkApiKey ?? '';
    if (_hithinkKeyCtrl.text.isEmpty && currentKey.isNotEmpty) {
      _hithinkKeyCtrl.text = currentKey;
    }
    return CollapsibleSectionCard(
      title: '同花顺数据源（备用）',
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('行情兜底第三路：东财、新浪都取不到时用它补。需填入 API Key（fuyao.aicubes.cn/admin 申请）；留空则不启用，行情照旧走东财/新浪。',
              style: hint),
          const SizedBox(height: 8),
          TextField(
            controller: _hithinkKeyCtrl,
            obscureText: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              hintText: '留空 = 不启用同花顺',
              hintStyle: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.6)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(kBoxRadius),
                borderSide: BorderSide(color: boxBorderColor(context)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(kBoxRadius),
                borderSide: BorderSide(color: boxBorderColor(context)),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            onChanged: (v) => st.setHithinkApiKey(v),
          ),
        ],
      ),
    );
  }

  /// 「安全设置」：生物识别解锁（可折叠，折叠状态会记住）
  Widget _securitySection(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    return CollapsibleSectionCard(
      title: '安全设置',
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('开启后，冷启动或从后台回来超过 30 秒，需要指纹 / 面容解锁才能查看数据',
              style: hint),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: st.biometricEnabled,
            title: const Text('生物识别解锁', style: TextStyle(fontSize: 14)),
            subtitle: Text('支持指纹与人脸；本机没有可用的指纹 / 面容时会提示',
                style: hint),
            onChanged: (v) async {
              var allow = v;
              if (v) {
                allow = await st.biometricAvailable();
                if (!allow && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('本机没有可用的指纹 / 面容，或尚未在系统设置里录入')));
                }
              } else {
                // 关闭前先验证一次身份，避免别人随手关掉
                allow = await st.verifyBiometric();
                if (!allow && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('未通过验证，安全设置保持不变')));
                }
              }
              if (allow) await st.setBiometric(v);
            },
          ),
        ],
      ),
    );
  }

  /// 「外观」：跟随系统 / 浅色 / 深色
  Widget _appearanceSection(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    // 用 SegmentedButton 而不是 RadioListTile：后者在 Flutter 3.32+ 已弃用，
    // 且这样和「分红方式」的选择器样式一致
    const modes = ['system', 'light', 'dark'];
    const labels = <String, String>{
      'system': '跟随系统',
      'light': '浅色',
      'dark': '深色',
    };
    return CollapsibleSectionCard(
      title: '外观',
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('切换整机的明暗', style: hint),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final m in modes)
                ButtonSegment(value: m, label: Text(labels[m] ?? m)),
            ],
            selected: {st.themeMode},
            onSelectionChanged: (s) => st.setThemeMode(s.first),
          ),
        ],
      ),
    );
  }

  /// 行情指标的筹码：**只写名称、不写代码**；不带删除叉（叉太容易误删），
  /// 删除走长按弹出的操作卡片。
  ///
  /// 点一下 = 在「已显示 / 待选」之间切换；长按 = 打开操作卡片。
  Widget _indexChip(BuildContext context, AppState st, IndexEntry e,
      {required bool on}) {
    final chip = InputChip(
      // 给每个筹码一个 key：下拉菜单要靠它对准位置（页面 context 算不准）
      key: _chipKeys.putIfAbsent(e.code, () => GlobalKey()),
      avatar: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 16),
      label: Text(e.label, style: const TextStyle(fontSize: 12)),
      onPressed: () => st.toggleIndexEntry(e.code),
      // 圆角与边框统一跟搜索框（InputChip 默认是胶囊形，和搜索框不是一套）
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kBoxRadius),
        side: BorderSide(color: boxBorderColor(context)),
      ),
      // 末尾是个「⋮」（**竖向**，和账户管理那边的更多操作一致；用户要求从横向改过来）
      // 点它或长按都打开操作菜单；删除要在菜单里再确认一次，避免误删
      onDeleted: () => _indexMenu(context, st, e),
      deleteIcon: const Icon(Icons.more_vert, size: 15),
      deleteButtonTooltipMessage: '更多操作',
    );
    // **不要再给筹码套 GestureDetector(onLongPress:)**：
    // 那个长按识别器会让"手指落在筹码上滑动"的拖动被吃掉 —— 页面滚不动
    // （实测：从左边空白滑页面会动，从筹码上滑完全不动）。
    // 打开操作菜单用末尾的 ⋮ 就够了，长按是多余的。
    // 筹码本身也不该抢焦点（点过它之后焦点会一直留着，滚动会被拽回去）。
    return ExcludeFocus(child: chip);
  }

  /// 点指标末尾的 ⋮ 弹出的操作菜单
  ///
  /// 用**下拉卡片**（`showMenu`）而不是底部弹窗 —— 和账户管理的 ⋮ 是同一套样子（用户要求）。
  /// 位置要**对准这个筹码**：`_indexChip` 收到的 context 是设置页的，不是筹码的，
  /// 拿它算位置菜单会飘到页面右下角，所以按代码存一个 GlobalKey 来定位。
  Future<void> _indexMenu(
      BuildContext context, AppState st, IndexEntry e) async {
    const red = Color(0xFFD93A3A);
    final act = await showMenu<String>(
      context: context,
      position: _menuPositionFor(_chipKeys[e.code]?.currentContext),
      items: [
        PopupMenuItem(
          value: 'toggle',
          child: Text(e.on ? '从跑马灯移除' : '加到跑马灯'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除', style: TextStyle(color: red)),
        ),
      ],
    );
    if (act == 'toggle') await st.toggleIndexEntry(e.code);
    if (act == 'delete') await st.removeIndexEntry(e.code);
    // **关掉菜单后要主动把焦点交还**：否则那个控件一直持有焦点，
    // 之后每次滚动都会被"把焦点控件拉进视野"拽回去 ——
    // 表现就是设置页整个滚不动（实测：点过筹码的 ⋮ 之后，下滑/上滑画面完全不变）。
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 把下拉菜单对齐到某个筹码的右下角；拿不到就退回原来的位置
  RelativeRect _menuPositionFor(BuildContext? anchor) {
    final ctx = anchor;
    if (ctx == null) return const RelativeRect.fromLTRB(0, 0, 0, 0);
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      return const RelativeRect.fromLTRB(0, 0, 0, 0);
    }
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight =
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    return RelativeRect.fromLTRB(
      topLeft.dx,
      bottomRight.dy,
      overlay.size.width - bottomRight.dx,
      0,
    );
  }

  /// 「行情指标」：跑马灯显示什么，可以按代码加指数 / ETF / 股票
  ///
  /// 池子里分两档：**已显示**（on=true）和**待选**（加了但没勾）。
  /// 点一下在两档之间来回，右侧 × 删除。
  Widget _marketSection(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    final active = [for (final e in st.indexPool) if (e.on) e];
    final pool = [for (final e in st.indexPool) if (!e.on) e];

    return CollapsibleSectionCard(
      title: '行情指标（显示 ${active.length}）',
      initiallyExpanded: true,
      showCollapseAtBottom: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('首页跑马灯显示这些指标（上证固定在标题栏，不在这里）', style: hint),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('已显示', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _addIndexDialog(st),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加指标'),
              ),
            ],
          ),
          if (active.isEmpty)
            Text('还没有显示中的指标', style: hint)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in active)
                  _indexChip(context, st, e, on: true),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('待选', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
              const SizedBox(width: 6),
              Text('（点一下加进跑马灯，长按可删除）', style: hint),
            ],
          ),
          const SizedBox(height: 4),
          // 该组一个标的都没有就整组不显示（不再出现「（无）」这种占位行）
          for (final g in const [
            ('broad', '大盘指数'),
            ('sector', '行业指数'),
            ('etf', '场内基金'),
          ])
            if (pool.any((e) => e.group == g.$1)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text('· ${g.$2}', style: hint),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in pool.where((e) => e.group == g.$1))
                    _indexChip(context, st, e, on: false),
                ],
              ),
            ],
          const Divider(height: 24),
          Text('常用指数一键添加', style: hint),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final idx in MarketIndex.presets)
                  ActionChip(
                    label: Text(idx.name, style: const TextStyle(fontSize: 12)),
                    onPressed: () => st.addIndexEntry(
                      IndexEntry(
                          code: idx.code,
                          name: idx.name,
                          short: idx.name,
                          kind: 'index'),
                      on: true,
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  /// 代码不在本地库里时按形态猜类型（决定价格小数位）
  static String _guessKind(String code) {
    if (RegExp(r'^(sh000|sz399|bj899)').hasMatch(code)) return 'index';
    if (RegExp(r'^(sh5|sz1)').hasMatch(code)) return 'etf';
    // 0 开头多为场外基金（021362 等）；000xxx/30xxxx 才是深市股票
    if (RegExp(r'^(sh0[1-9]|sz0[1-9])').hasMatch(code)) return 'fund';
    if (RegExp(r'^(sh6|sz0|sz3|bj8|bj4)').hasMatch(code)) return 'stock';
    return 'fund';
  }

  static String _kindLabel(String kind) => switch (kind) {
        'index' => '指数',
        'etf' => 'ETF',
        'stock' => '股票',
        'fund' => '场外基金',
        _ => '',
      };

  /// 添加指标：填代码 → 本地基金库查名字 → 查不到再联网查 → 让用户定简称
  Future<void> _addIndexDialog(AppState st) async {
    final codeCtrl = TextEditingController();
    final shortCtrl = TextEditingController();
    var name = '';
    var kind = 'index';
    var price = 0.0;
    var pct = 0.0;
    var lookState = 'idle'; // idle | busy | ok | fail
    String? message;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> lookup() async {
            final raw = codeCtrl.text.trim();
            if (raw.isEmpty) return;
            setLocal(() {
              lookState = 'busy';
              message = null;
            });
            final code = normalizeIndexCode(raw);

            // 1) 先查本地基金/股票库（离线也能拿到名字）
            final bare = code.replaceAll(RegExp(r'^[a-z]{2}'), '');
            final found = await st.securityByCode(bare);
            name = found?.name ?? '';
            kind = found?.kind ?? _guessKind(code);
            price = 0;
            pct = 0;
            // 2) 再联网拿一次名称+最新价+涨幅（本地库没有行情）
            //    东财 push2 是 UTF-8 JSON，不像新浪精简行情那样是 GBK
            try {
              final q = await st.market.lookupIndex(code);
              if (q != null) {
                if (name.isEmpty) name = q.name;
                price = q.price;
                pct = q.changePct;
              }
            } catch (_) {
              // 网络失败就退回"本地名字 / 用代码当名字"
            }
            setLocal(() {
              if (name.isEmpty) {
                lookState = 'fail';
                message = '没有查到这只标的，可以直接用代码当简称';
                shortCtrl.text = code;
              } else {
                lookState = 'ok';
                final digits = priceDigitsForKind(kind);
                message = price > 0
                    ? '已识别（${_kindLabel(kind)}）：$name  '
                        '${price.toStringAsFixed(digits)}  '
                        '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%'
                    : '已识别（${_kindLabel(kind)}）：$name';
                shortCtrl.text = defaultIndexShort(name);
              }
            });
          }

          return AlertDialog(
            title: const Text('添加行情指标'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: codeCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '代码',
                      hintText: 'sh000300 / 510300 / sh510905',
                      helperText: '指数写 sh/sz 前缀（sh000300 沪深300）；ETF、股票直接写 6 位代码即可',
                      helperMaxLines: 2,
                      isDense: true,
                    ),
                    onSubmitted: (_) => lookup(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: lookState == 'busy' ? null : lookup,
                      icon: lookState == 'busy'
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search, size: 18),
                      label: const Text('查名称'),
                    ),
                  ),
                  if (message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(message!,
                          style: TextStyle(
                            fontSize: 12,
                            color: lookState == 'fail'
                                ? const Color(0xFFB4770A)
                                : Theme.of(ctx).hintColor,
                          )),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: shortCtrl,
                    decoration: const InputDecoration(
                      labelText: '跑马灯简称',
                      hintText: '沪深300',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () async {
                  final code = normalizeIndexCode(codeCtrl.text);
                  if (code.isEmpty) return;
                  // 只有真正的**场外基金**才拦：场内代码（510300 / 159915 …）即便本地库
                  // 把它标成 fund，也照样能取到实时价，不能拦
                  final exchangeLike =
                      RegExp(r'^(sh5|sz1|sh6|sz0|sz3)').hasMatch(code);
                  if (kind == 'fund' && !exchangeLike) {
                    setLocal(() {
                      message = '场外基金没有实时行情，不能加到跑马灯；请换成对应的场内 ETF 代码';
                      lookState = 'fail';
                    });
                    return;
                  }
                  final s = shortCtrl.text.trim();
                  await st.addIndexEntry(
                    IndexEntry(
                      code: code,
                      name: name,
                      short: s.isEmpty ? code : s,
                      kind: kind,
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  _snack('已加入待选：${s.isEmpty ? code : s}');
                },
                child: const Text('加入待选'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String title) => Padding(        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: Theme.of(context).hintColor,
          ),
        ),
      );

  /// 更新金融基础数据 = 基金 + 股票，一次点完（用户要求合并成一项）
  Future<void> _updateSecurities(AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新金融基础数据'),
        content: const Text(
          '会依次更新两部分：\n'
          '· 基金：联网下载全量基金列表（约 3 MB，含 ETF / LOF）\n'
          '· 股票：分页拉取全部 A 股（约 5,600 只，56 页）\n\n'
          '只在本次点击时联网，之后搜索都走本地。\n'
          '中途失败或退出会保留已写入的数据，再次点击从断点继续。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始更新')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final fund = await st.updateFundSecurities();
    if (!mounted) return;
    final stock = await st.updateStockSecurities();
    if (!mounted) return;
    _snack('基金 ${fund > 0 ? '+$fund' : '未更新'} 条 · '
        '股票 ${stock > 0 ? '+$stock' : '未更新'} 条');
  }

  Future<void> _clearSecurities(AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空基础数据库？'),
        content: const Text(
          '只会清空基金/股票的代码、名称、首拼、类型、板块。\n'
          '你的账户、持仓、流水、再平衡目标都不受影响，随时可以重新更新。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD93A3A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await st.clearSecuritiesDb();
    if (!mounted) return;
    _snack('基础数据库已清空');
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  Future<void> _export(String fileName, String content, String title) async {
    setState(() => _busy = true);
    try {
      final dir = await FileStore.exportDir();
      final f = await FileStore.writeCsv(dir, fileName, content);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$title 已导出'),
          content: SingleChildScrollView(
            child: SelectableText(
              '文件路径：\n${f.path}\n\n'
              '取回电脑：\nadb pull "${f.path}" .\n\n'
              '（CSV 带 UTF-8 BOM，Excel 直接打开中文不乱码）',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    } catch (e) {
      _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportBackup() async {
    final st = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final path = await st.exportBackupToFile();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('全局备份已导出'),
          content: SingleChildScrollView(
            child: SelectableText(
              '文件路径：\n$path\n\n'
              '包含：账户、标的与分类、全部交易流水、现金流水、再平衡目标、\n'
              '关注列表、定投计划、设置，以及金融基础数据与历史净值。\n'
              '（不含行情缓存，恢复后会自动重新抓取）\n\n'
              '取回电脑：\nadb pull "$path" .',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    } catch (e) {
      _snack('备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    final st = context.read<AppState>();
    final currentCount = st.txns.length;
    setState(() => _busy = true);
    try {
      final files = await FileStore.listBackups();
      if (!mounted) return;

      if (files.isEmpty) {
        final dir = await FileStore.importDir();
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('没有找到备份文件'),
            content: SingleChildScrollView(
              child: SelectableText(
                '把备份 JSON 放进下面的目录，再重新点「从备份恢复」：\n\n'
                '${dir.path}\n\n'
                '在电脑上执行：\nadb push 完整备份.json "${dir.path}/"',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
            ],
          ),
        );
        return;
      }

      final picked = await showDialog<File>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要恢复的备份'),
          children: [
            for (final f in files)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.basename(f.path), style: const TextStyle(fontSize: 14)),
                    Text(
                      '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB · '
                      '${fmtDateTime(f.lastModifiedSync())}',
                      style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;

      final text = await FileStore.readText(picked);
      AppBackup preview;
      try {
        preview = AppBackup.decode(text);
      } on BackupException catch (e) {
        _snack('无法读取该备份：${e.message}');
        return;
      }
      if (!mounted) return;

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认恢复？'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('备份时间：${fmtDateTime(preview.exportedAt)}',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Text(
                  '账户 ${preview.accountCount} 个 · 标的 ${preview.usedAssetCount} 个 · '
                  '流水 ${preview.txns.length} 笔 · 再平衡目标 ${preview.targets.length} 项',
                  style: const TextStyle(fontSize: 13),
                ),
                // 全局备份（v4）还带这两块，得如实说 —— 它们也会被整体覆盖
                if (preview.navHistoryCount > 0 ||
                    preview.securities.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '另含 金融基础数据 ${preview.securities.length} 条 · '
                    '历史净值 ${preview.navHistoryCount} 条（同样会被覆盖）',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
                const SizedBox(height: 14),
                const Text(
                  '恢复会用备份内容整体覆盖当前数据，当前数据无法找回。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFD93A3A)),
                ),
                const SizedBox(height: 6),
                Text(
                  '当前有 $currentCount 笔流水，恢复后将被替换。',
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD93A3A)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('覆盖恢复'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;

      final count = await st.restoreBackup(text);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复完成'),
          content: Text('已恢复 $count 笔交易流水，行情正在重新获取。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好')),
          ],
        ),
      );
    } catch (e) {
      _snack('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final files = await FileStore.listCsv();
      if (!mounted) return;
      if (files.isEmpty) {
        final dir = await FileStore.importDir();
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('没有找到 CSV 文件'),
            content: SingleChildScrollView(
              child: SelectableText(
                '请先把 CSV 放进下面的目录，然后重新点「导入」：\n\n'
                '${dir.path}\n\n'
                '在电脑上执行：\nadb push 你的文件.csv "${dir.path}/"\n\n'
                '也可以先导出一次，再直接导入导出的文件。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
            ],
          ),
        );
        return;
      }

      final picked = await showDialog<File>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要导入的 CSV'),
          children: [
            for (final f in files)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.basename(f.path), style: const TextStyle(fontSize: 14)),
                    Text(
                      '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB · '
                      '${fmtDateTime(f.lastModifiedSync())}',
                      style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;

      final content = await FileStore.readText(picked);
      final result = await context.read<AppState>().importTxns(content);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('成功导入 ${result.rows.length} 笔记录',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                if (result.errors.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('${result.errors.length} 条被跳过：',
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  for (final e in result.errors.take(10))
                    Text('· $e',
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(ctx).hintColor)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDirs() async {
    final exp = await FileStore.exportDir();
    final imp = await FileStore.importDir();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('数据目录'),
        content: SingleChildScrollView(
          child: SelectableText(
            '导出目录：\n${exp.path}\n\n'
            '导入目录：\n${imp.path}\n\n'
            '收发文件示例：\n'
            'adb push 流水.csv "${imp.path}/"\n'
            'adb pull "${exp.path}" .',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Widget _aboutSection(BuildContext context) {
    return CollapsibleSectionCard(
      title: '关于',
      initiallyExpanded: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _showAboutDetail(context),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(appVersionLine,
                        style: const TextStyle(fontSize: 14)),
                  ),
                  Icon(Icons.info_outline,
                      size: 18, color: Theme.of(context).hintColor),
                ],
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.system_update_alt, size: 20),
            title: const Text('检查更新', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '联网查一下有没有新版本（只查看，不会自动下载安装）',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right, size: 20),
            onTap: _checkingUpdate ? null : _checkUpdate,
          ),
        ],
      ),
    );
  }

  /// 检查更新：只查最新版号并给出下载页，绝不静默下载安装
  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    // 传设备 ABI：拆分打包后发行版里有多个架构的包，要挑对的那个
    final abi = await ApkUpdater.deviceAbi();
    final res = await checkUpdate(deviceAbi: abi);
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    if (res == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('检查更新失败'),
          content: const Text(
            '没能连上代码托管平台（GitHub / Gitee）。\n\n'
            '常见原因：当前网络访问 GitHub 受限。可以去 Gitee 镜像仓库手动看最新版本。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
      return;
    }

    final info = res.newest;
    // 发布策略是"只在值得的版本传附件"，所以最新版常常没有安装包；
    // 这时若更早的版本有包，就把那一版指出来 —— 否则应用内更新
    // 只在刚发完包的那阵子可用。
    final inst = res.installable;
    final hasNew = isNewerVersion(info.latest, appVersion);
    // 可安装的那版比当前还新，才算"能用应用内升级"
    final canAuto = inst != null && isNewerVersion(inst.latest, appVersion);

    if (!hasNew && !canAuto) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已是最新版本'),
          content: Text(
            '当前版本：v$appVersion\n'
            '最新版本：v${info.latest}（来源 ${info.source}）\n\n'
            '暂时不用更新。',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
      return;
    }

    final target = canAuto ? inst : info;
    final olderThanNewest = canAuto && target.latest != info.latest;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${canAuto ? target.latest : info.latest}'),
        content: Text(
          '当前版本：v$appVersion\n'
          '最新版本：v${info.latest}（来源 ${info.source}）\n'
          '${olderThanNewest ? '可安装版本：v${target.latest}（这一版提供了安装包）\n' : ''}'
          '\n'
          '${canAuto ? '可以直接在应用内下载并安装（下载完系统会让你确认一次安装）。'
              '新版与当前包同签名，装上会直接覆盖、数据不丢。' : '这个最新版没有适配你机型的安装包'
              '（发布时没上传附件，或只出了别的 CPU 架构的包）。'
              '可以打开下载页手动看看：\n\n${info.url}'}',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
          if (canAuto)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载并安装'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('知道了'),
            ),
        ],
      ),
    );

    if (go != true || !canAuto || !context.mounted) return;
    await _downloadAndInstall(target);
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
            '下一步会打开系统设置，请把「调仓助手」这一项打开，再回来重新点「检查更新」。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去设置')),
          ],
        ),
      );
      if (go == true) await ApkUpdater.openInstallSettings();
      return;
    }

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

  /// 关于明细：默认不铺在设置页上，点一下才弹
  Future<void> _showAboutDetail(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('调仓助手 v$appVersion'),
        content: SingleChildScrollView(
          child: Text(
            '吹角天明@MLB\n\n'
            '数据全部保存在手机本地（SQLite），不上传任何服务器。\n'
            '行情来源：东方财富公开接口（天天基金净值、交易所行情）。\n'
            '成本核算采用移动加权平均法；年化收益率按现金流 XIRR 计算。\n\n'
            '本工具仅用于个人投资记账与统计，行情数据可能存在延迟或误差，'
            '不构成任何投资建议。',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).hintColor,
                height: 1.7),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
