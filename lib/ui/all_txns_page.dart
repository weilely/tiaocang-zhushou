import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';
import 'widgets/txn_history.dart';

/// 全部交易（跨标的）：**按基金 / 股票分组**，支持批量删除
///
/// 分组顺序按名称（没名称按代码）；组内按日期倒序。进多选后左侧变勾选框，
/// 底部一条操作栏可以全选 / 删除，删除会连带清掉该笔交易联动生成的现金流水
/// （和单笔删除同一个入口 `AppState.removeTxn`）。
class AllTxnsPage extends StatefulWidget {
  const AllTxnsPage({super.key});

  @override
  State<AllTxnsPage> createState() => _AllTxnsPageState();
}

class _AllTxnsPageState extends State<AllTxnsPage> {
  bool _selecting = false;
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.txns
        .where((t) =>
            state.accountFilter == null || t.accountId == state.accountFilter)
        .toList();

    final bought = list
        .where((t) => t.type == TxnType.buy)
        .fold<double>(0, (a, t) => a + t.amount);
    final sold = list
        .where((t) => t.type == TxnType.sell)
        .fold<double>(0, (a, t) => a + t.amount);
    final fee = list.fold<double>(0, (a, t) => a + t.fee);

    // 按标的聚合
    final groups = <int, List<Txn>>{};
    for (final t in list) {
      (groups[t.assetId] ??= <Txn>[]).add(t);
    }
    for (final g in groups.values) {
      g.sort((a, b) => b.date.compareTo(a.date));
    }
    String nameOf(int assetId) {
      final a = state.assetsById[assetId];
      if (a == null) return '未知标的';
      return a.name.isEmpty ? a.code : a.name;
    }

    final ids = groups.keys.toList()
      ..sort((x, y) => nameOf(x).compareTo(nameOf(y)));

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length} 笔' : '全部交易'),
        actions: [
          if (list.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (_selecting) {
                  _selecting = false;
                  _selected.clear();
                } else {
                  _selecting = true;
                }
              }),
              child: Text(_selecting ? '取消' : '批量删除'),
            ),
        ],
        bottom: list.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(38),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      Text('共 ${list.length} 笔 · ${ids.length} 只',
                          style: TextStyle(
                              fontSize: 12, color: Theme.of(context).hintColor)),
                      const Spacer(),
                      Text('买入 ${fmtCompact(bought)}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFD93A3A))),
                      const SizedBox(width: 10),
                      Text('卖出 ${fmtCompact(sold)}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1A9C5B))),
                      const SizedBox(width: 10),
                      Text('费 ${fmtCompact(fee)}',
                          style: TextStyle(
                              fontSize: 12, color: Theme.of(context).hintColor)),
                    ],
                  ),
                ),
              ),
      ),
      body: list.isEmpty
          ? const EmptyHint(
              icon: Icons.receipt_long_outlined,
              text: '还没有交易记录\n去「持仓」页记一笔',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
              children: [
                for (final id in ids)
                  _group(context, state, id, groups[id]!, nameOf(id)),
              ],
            ),
      bottomNavigationBar: _selecting ? _selectBar(context, state, list) : null,
    );
  }

  /// 底部操作栏：全选 / 删除
  Widget _selectBar(BuildContext context, AppState state, List<Txn> all) {
    final total = all.length;
    final allSelected = _selected.length == total;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll([for (final t in all) if (t.id != null) t.id!]);
                }
              }),
              icon: Icon(allSelected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked),
              label: Text(allSelected ? '取消全选' : '全选'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : () => _confirmDelete(state),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD93A3A),
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text('删除 ${_selected.length} 笔'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(AppState state) async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 $n 笔记录？'),
        content: const Text(
          '这些交易联动生成的现金流水会一并删掉（现金余额跟着变），删除后不能撤销。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD93A3A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    for (final id in _selected.toList()) {
      await state.removeTxn(id);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $n 笔'), duration: const Duration(seconds: 2)),
    );
  }

  /// 一只标的的分组：标题行（可整组勾选）+ 该标的的全部交易
  Widget _group(
    BuildContext context,
    AppState state,
    int assetId,
    List<Txn> txns,
    String name,
  ) {
    final asset = state.assetsById[assetId];
    final bought = txns
        .where((t) => t.type == TxnType.buy)
        .fold<double>(0, (a, t) => a + t.amount);
    final sold = txns
        .where((t) => t.type == TxnType.sell)
        .fold<double>(0, (a, t) => a + t.amount);
    final groupIds = [for (final t in txns) if (t.id != null) t.id!];
    final allIn = groupIds.isNotEmpty && groupIds.every(_selected.contains);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: _selecting
                  ? () => setState(() {
                        if (allIn) {
                          _selected.removeAll(groupIds);
                        } else {
                          _selected.addAll(groupIds);
                        }
                      })
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    if (_selecting)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(
                          allIn
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: allIn
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).hintColor,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700)),
                          Text(
                            '${asset?.code ?? ''} · ${asset?.kind.label ?? ''}'
                            ' · ${txns.length} 笔',
                            style: TextStyle(
                                fontSize: 11, color: Theme.of(context).hintColor),
                          ),
                        ],
                      ),
                    ),
                    if (bought > 0)
                      Text('买 ${fmtCompact(bought)}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFD93A3A))),
                    if (bought > 0 && sold > 0) const SizedBox(width: 8),
                    if (sold > 0)
                      Text('卖 ${fmtCompact(sold)}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF1A9C5B))),
                  ],
                ),
              ),
            ),
            const Divider(height: 4),
            for (final t in txns)
              txnTile(
                context,
                t,
                highlightNote: '定投',
                selectable: _selecting,
                selected: t.id != null && _selected.contains(t.id),
                onToggle: () => setState(() {
                  if (t.id == null) return;
                  if (!_selected.remove(t.id!)) _selected.add(t.id!);
                }),
              ),
          ],
        ),
      ),
    );
  }
}
