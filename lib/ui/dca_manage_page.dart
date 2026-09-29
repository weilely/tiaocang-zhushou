import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/dca_models.dart';
import '../data/models.dart';
import '../logic/dca.dart';
import '../state/app_state.dart';
import 'asset_detail_page.dart';
import 'dca_plan_sheet.dart';
import 'widgets/common.dart';

/// 定投管理：所有计划的启停、编辑、立即补记与删除
class DcaManagePage extends StatelessWidget {
  const DcaManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final plans = state.dcaPlans;

    return Scaffold(
      appBar: AppBar(
        title: const Text('定投管理'),
        actions: [
          IconButton(
            tooltip: '新增定投计划',
            onPressed: () => _addPlan(context, state),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: '立即补记全部计划',
            onPressed: state.dcaRunning ? null : () => _runAll(context, state),
            icon: state.dcaRunning
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_circle_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          SectionCard(
            title: '自动补记',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: state.dcaAutoRun,
                  onChanged: (v) => state.setDcaAutoRun(v),
                  title: const Text('打开应用时自动补齐', style: TextStyle(fontSize: 14)),
                ),
                Text(
                  '关掉后不会自动生成任何交易，只在你手动点右上角「立即补记」时才补。\n'
                  '每一期都用那一期真实的净值/收盘价算份额；取不到价格就跳过，下次重试。',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
                ),
              ],
            ),
          ),
          if (plans.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: EmptyHint(
                icon: Icons.event_repeat_outlined,
                text: '还没有定投计划\n点右上角「+」新建，也可以在持仓详情页点「定投」',
                action: FilledButton.icon(
                  onPressed: () => _addPlan(context, state),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新增定投计划'),
                ),
              ),
            )
          else
            for (final p in plans) _planCard(context, state, p),
        ],
      ),
    );
  }

  Widget _planCard(BuildContext context, AppState state, DcaPlan p) {
    final asset = state.assetsById[p.assetId];
    final account = state.accountsById[p.accountId];
    final next = nextDcaDate(p, DateTime.now());
    final fee = dcaFeeFor(amount: p.amount, feeRatePct: p.feeRate);
    // 「已补记 N 笔」按**这条计划**数（同标的多计划时不能按标的数一遍，
    // 否则两条计划会显示同一个数字）；老数据没有 dcaPlanId，退回按备注+同标的。
    final legacyWide = state.dcaPlansFor(p.accountId, p.assetId).length == 1;
    final generated = state.txns
        .where((t) => t.accountId == p.accountId && t.assetId == p.assetId)
        .where((t) => p.id != null && t.dcaPlanId == p.id ||
            (legacyWide && t.note.startsWith('定投')))
        .length;

    return SectionCard(
      title: asset?.name.isNotEmpty == true ? asset!.name : (asset?.code ?? '未知标的'),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: (p.enabled ? const Color(0xFF1A9C5B) : Theme.of(context).hintColor)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          p.enabled ? '启用中' : '已暂停',
          style: TextStyle(
              fontSize: 10,
              color: p.enabled ? const Color(0xFF1A9C5B) : Theme.of(context).hintColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.summary, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '${asset?.code ?? ''} · ${account?.name ?? ''}\n'
            '${p.rangeLabel}'
            ' · ${next == null ? (p.endedBy(DateTime.now()) ? '已到期' : '下次扣款 --') : '下次扣款 ${fmtDate(next)}'}'
            ' · 已补记 $generated 笔'
            '${fee > 0 ? ' · 手续费 ¥${fee.toStringAsFixed(2)}/期' : ''}'
            '${p.note.isEmpty ? '' : ' · ${p.note}'}',
            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton.icon(
                onPressed: state.dcaRunning ? null : () => _runOne(context, state, p),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('立即补记'),
              ),
              const Spacer(),
              IconButton(
                tooltip: p.enabled ? '暂停' : '启用',
                icon: Icon(p.enabled
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline),
                onPressed: () => state.setDcaEnabled(p.id!, !p.enabled),
              ),
              IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showDcaPlanSheet(
                  context,
                  accountId: p.accountId,
                  assetId: p.assetId,
                  existing: p,
                ),
              ),
              IconButton(
                tooltip: '查看持仓',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AssetDetailPage(
                      accountId: p.accountId, assetId: p.assetId),
                )),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _runAll(BuildContext context, AppState state) async {
    final report = await state.runDueDca(manual: true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(report.summary), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _runOne(BuildContext context, AppState state, DcaPlan p) async {
    // 单计划补记：临时只跑它 —— 复用全局流程即可（其它计划已补过不会被重复生成）
    final report = await state.runDueDca(manual: true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(report.summary), duration: const Duration(seconds: 4)),
    );
  }

  /// 新增定投计划：先选「账户 + 标的」，再打开计划弹层
  ///
  /// 只列该账户**当前持有**的标的 —— 没有持仓的标的建出来会被补记流程立刻自动停用
  /// （`runDueDca` 里「标的已清仓的计划自动停用」）。
  ///
  /// 用户 2026-09-29：「同一个标的可设置多个定投」——所以**不再**因为该标的有计划就
  /// 跳去编辑，而是新建一条；已有计划的数量在选标的时标出来（想改哪条就在列表里点
  /// 那条的铅笔）。
  Future<void> _addPlan(BuildContext context, AppState state) async {
    if (state.accounts.isEmpty) return;
    final picked = await showModalBottomSheet<({int accountId, int assetId})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PlanTargetPicker(
        initialAccountId: state.accountFilter ?? state.accounts.first.id!,
      ),
    );
    if (picked == null || !context.mounted) return;
    await showDcaPlanSheet(
      context,
      accountId: picked.accountId,
      assetId: picked.assetId,
    );
  }
}

/// 「新增定投」的选标的弹层（账户 + 该账户当前持有的标的）
class _PlanTargetPicker extends StatefulWidget {
  const _PlanTargetPicker({required this.initialAccountId});

  final int initialAccountId;

  @override
  State<_PlanTargetPicker> createState() => _PlanTargetPickerState();
}

class _PlanTargetPickerState extends State<_PlanTargetPicker> {
  late int _picked = widget.initialAccountId;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final accounts = st.accounts;
    if (accounts.isEmpty) return const SizedBox.shrink();
    // 选中的账户可能已经不在了（切换/删除过）→ 退回第一个，别拿空列表渲染
    final accountId =
        accounts.any((a) => a.id == _picked) ? _picked : accounts.first.id!;
    final held = [
      for (final p in st.positionsOf(accountId))
        if (!p.isEmpty) p.asset,
    ]..sort((a, b) => a.code.compareTo(b.code));

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('新增定投计划',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '选一个该账户当前持有的标的（没有持仓的标的建了会被自动暂停）。'
              '同一个标的可以建多条计划（比如每周小额定投 + 每月大额定投）；'
              '想改哪条，回列表点那条的铅笔。',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor, height: 1.5),
            ),
            const SizedBox(height: 14),
            if (accounts.length > 1)
              DropdownButtonFormField<int>(
                initialValue: accountId,
                decoration: const InputDecoration(labelText: '账户'),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id!, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _picked = v ?? accountId),
              )
            else
              Text('账户：${accounts.first.name}',
                  style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            if (held.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text('该账户当前没有持仓，先去持仓页把标的加进来',
                    style:
                        TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
              )
            else
              for (final a in held)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(a.name.isEmpty ? a.code : a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text('${a.code} · ${a.kind.label}',
                      style: TextStyle(
                          fontSize: 11, color: Theme.of(context).hintColor)),
                  trailing: switch (st.dcaPlansFor(accountId, a.id!).length) {
                    // 同标的可以挂多条计划（用户 2026-09-29）→ 标出已有几条，
                    // 点进去是**再建一条**；想改哪条回列表点那条的铅笔
                    0 => const Icon(Icons.chevron_right, size: 20),
                    final n => Text('已有 $n 条',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary)),
                  },
                  onTap: () => Navigator.of(context)
                      .pop((accountId: accountId, assetId: a.id!)),
                ),
          ],
        ),
      ),
    );
  }
}
