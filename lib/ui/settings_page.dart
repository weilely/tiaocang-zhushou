import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/file_store.dart';
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

  /// 调仓目标：标的代码 → 目标占比输入框
  final Map<String, TextEditingController> _targetCtrl = {};

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

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();

    // 设置已是底部第 5 个页签，标题栏由外壳提供，所以这里不再自带 Scaffold/AppBar。
    // 忙碌进度条内联到列表顶部，保留「正在处理」的反馈。
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _accountSection(context, st),
        _targetSection(context, st),
        _dataSection(context, st),
        _marketSection(context, st),
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
      trailing: TextButton.icon(
        onPressed: _addAccount,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('新增'),
      ),
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
              '库内 ${st.navRowCount} 条 · ${st.navUpdatedAt == null ? '尚未更新过' : '上次更新 ${fmtDateTime(st.navUpdatedAt!)}'}\n'
              '基金取天天基金的全部历史、指数取新浪日K；净值日期固定按北京时间折算',
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
            subtitle: Text(
              '清掉本地净值再全量重抓，用来修日期错位',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
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
              '基金 ${st.securitiesFundCount} 条 · 股票 ${st.securitiesStockCount} 条 · $lastSec\n'
              '存代码、名称、拼音首拼、类型、板块；只在点「更新」时才联网',
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
            title: const Text('更新基金基础数据', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '一次请求约 3 MB、约 2.8 万条，含 ETF / LOF，自带首拼与类型',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: () => _updateFundSecurities(st),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            enabled: !st.securitiesBusy,
            leading: const Icon(Icons.show_chart_outlined, size: 20),
            title: const Text('更新股票基础数据', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '分页拉取约 5,600 只 A 股（上证/深证/创业/科创/北证），首拼本地生成',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: () => _updateStockSecurities(st),
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
            title: const Text('导出完整备份（推荐）', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '账户、分类、全部流水、再平衡目标、设置；每天首次启动还会自动备份一份',
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
            subtitle: Text(
              '含成本、市值、浮动/已实现盈亏、年化收益率',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
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
            subtitle: Text(
              '从应用目录中选取 CSV 文件',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: _import,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.folder_open_outlined, size: 20),
            title: const Text('查看数据目录', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '用 adb 可在电脑与模拟器之间收发文件',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            onTap: _showDirs,
          ),
        ],
      ),
    );
  }

  /// 「行情指标」：**按三类分栏**（大盘指数 / 行业指数 / 场内基金），
  /// 每类各有「已显示」和「待选」两档；类别在添加时按代码与基金库自动判定，
  /// 三类各走各的行情通道（指数走新浪大盘指数 + 东财，场内基金走东财）。
  Widget _marketSection(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    const groups = [
      ('broad', '大盘指数'),
      ('sector', '行业指数'),
      ('etf', '场内基金'),
    ];

    List<IndexEntry> onOf(String g) =>
        [for (final e in st.indexPool) if (e.on && e.group == g) e];
    List<IndexEntry> offOf(String g) =>
        [for (final e in st.indexPool) if (!e.on && e.group == g) e];

    Widget chips(List<IndexEntry> list, {required bool on}) {
      if (list.isEmpty) {
        return Text(on ? '（空）' : '（无）', style: hint);
      }
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in list)
            InputChip(
              avatar: Icon(
                on ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 16,
              ),
              label: Text('${e.label}（${e.code}）',
                  style: const TextStyle(fontSize: 12)),
              onPressed: () => st.toggleIndexEntry(e.code),
              onDeleted: () => st.removeIndexEntry(e.code),
              deleteIcon: const Icon(Icons.close, size: 14),
            ),
        ],
      );
    }

    final activeCount = st.indexPool.where((e) => e.on).length;

    return CollapsibleSectionCard(
      title: '行情指标（显示 $activeCount）',
      initiallyExpanded: true,
      storageKey: 'card:行情指标',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('首页跑马灯显示这些指标。三类各走各的行情通道，价格与涨幅每分钟自动刷新'
              '（上证固定在标题栏，不在这里）', style: hint),
          if (st.indexQuoteDiag.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('上次取数：${st.indexQuoteDiag}', style: hint),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('已显示',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).hintColor)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _addIndexDialog(st),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加指标'),
              ),
            ],
          ),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text('· ${g.$2}', style: hint),
            ),
            chips(onOf(g.$1), on: true),
            const SizedBox(height: 8),
          ],
          const Divider(height: 20),
          Text('待选（点一下加进跑马灯）', style: hint),
          const SizedBox(height: 6),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text('· ${g.$2}', style: hint),
            ),
            chips(offOf(g.$1), on: false),
            const SizedBox(height: 8),
          ],
          const Divider(height: 20),
          Text('常用大盘指数一键添加', style: hint),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final idx in MarketIndex.presets)
                if (!st.indexPool.any((e) => e.code == idx.code))
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

  Future<void> _updateFundSecurities(AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新基金基础数据'),
        content: const Text(
          '将联网下载全量基金列表（约 3 MB，含 ETF / LOF）。\n'
          '只在本次点击时联网，之后搜索都走本地。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始更新')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final n = await st.updateFundSecurities();
    if (!mounted) return;
    _snack(n > 0 ? '基金基础数据已更新：$n 条' : '更新失败或未获得数据');
  }

  Future<void> _updateStockSecurities(AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更新股票基础数据'),
        content: const Text(
          '将联网分页拉取全部 A 股（约 5,600 只，56 页）。\n'
          '中途失败或退出会保留已写入的数据，再次点击从断点继续。\n'
          '首拼由本地字典生成，不需要额外联网。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始更新')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final n = await st.updateStockSecurities();
    if (!mounted) return;
    _snack(n > 0 ? '股票基础数据已更新：$n 条' : '更新失败或未获得数据');
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
          title: const Text('完整备份已导出'),
          content: SingleChildScrollView(
            child: SelectableText(
              '文件路径：\n$path\n\n'
              '包含：账户、标的与分类、全部交易流水、再平衡目标、设置。\n'
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
      child: InkWell(
        onTap: () => _showAboutDetail(context),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('调仓助手 v1.0.0　吹角天明@MLB',
                    style: TextStyle(fontSize: 14)),
              ),
              Icon(Icons.info_outline,
                  size: 18, color: Theme.of(context).hintColor),
            ],
          ),
        ),
      ),
    );
  }

  /// 关于明细：默认不铺在设置页上，点一下才弹
  Future<void> _showAboutDetail(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调仓助手 v1.0.0'),
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
