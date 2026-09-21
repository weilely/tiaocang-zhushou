import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/dca_models.dart';
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
                  '每一期都用**那一期真实的净值/收盘价**算份额；取不到价格就跳过，下次重试。',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
                ),
              ],
            ),
          ),
          if (plans.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyHint(
                icon: Icons.event_repeat_outlined,
                text: '还没有定投计划\n在持仓详情页点「定投」即可创建',
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
    final generated = state.txns
        .where((t) => t.accountId == p.accountId && t.assetId == p.assetId)
        .where((t) => t.note.startsWith('定投'))
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
            '下次扣款 ${next == null ? '--' : fmtDate(next)}'
            ' · 已补记 $generated 笔'
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
}
