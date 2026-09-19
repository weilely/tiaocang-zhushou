import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../data/nav_models.dart';

/// 现金流水的一行
///
/// **联动生成的那条不允许在这里删除**：它是买入/卖出/分红/定投的影子，
/// 单独删掉会让现金余额与交易对不上。
/// 这里做成「结构与行为上的不可能」——[onDelete] 为 null 时**根本不构造**
/// `Dismissible`，而不是构造了再判断，避免以后有人改错条件又把删入口放出来。
class CashTxnTile extends StatelessWidget {
  final CashTxn txn;

  /// 账户名（「全部账户」视图下才需要显示）
  final String accountName;

  /// 左滑删除的回调；**联动流水传 null**，表示不可删
  final VoidCallback? onDelete;

  const CashTxnTile({
    super.key,
    required this.txn,
    this.accountName = '',
    this.onDelete,
  });

  /// 是否由交易联动生成
  bool get isAuto => txn.srcTxnId != null;

  /// 定投联动生成的买入：现金流水里标题直接写「定投」，与交易记录里的标签一致
  bool get isDca => txn.type == CashType.invest && txn.note.contains('定投');

  bool get deletable => onDelete != null && !isAuto;

  /// 标题：定投走「定投」，其余用类型名
  String get _title => isDca ? '定投' : txn.typeLabel;

  /// 副标题里的备注。
  ///
  /// 联动流水的备注是「简称 · 动作词」，而动作词标题已经写了 —— 这里把动作词去掉，
  /// 只留标的简称，免得一行里出现两遍「买入 / 定投」。手记流水原样显示。
  String get _note {
    if (txn.note.isEmpty) return '';
    if (!isAuto) return txn.note;
    final parts = txn.note
        .split(' · ')
        .where((s) {
          final t = s.trim();
          return t.isNotEmpty && t != '定投' && t != txn.typeLabel;
        })
        .toList();
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = txn.amount >= 0;
    final color = txn.isIncome
        ? const Color(0xFFB4770A)
        : (positive ? const Color(0xFFD93A3A) : const Color(0xFF1A9C5B));
    final note = _note;

    final tile = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Row(
        children: [
          Text(_title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (isAuto) ...[
            const SizedBox(width: 6),
            const _AutoTag(),
          ],
        ],
      ),
      subtitle: Text(
        '${fmtDate(txn.date)}${accountName.isEmpty ? '' : ' · $accountName'}'
        '${note.isEmpty ? '' : ' · $note'}',
        style: TextStyle(fontSize: 11, color: theme.hintColor),
      ),
      trailing: Text(
        '${positive ? '+' : '-'}${fmtMoney(txn.amount.abs())}',
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: color),
      ),
    );

    // 联动流水：直接返回普通行，连 Dismissible 都不造
    if (!deletable) return tile;

    return Dismissible(
      key: ValueKey('cash-${txn.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: const Color(0xFFD93A3A),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      // 左滑先弹确认框：现金流水删掉就没法反悔，误滑的代价太大。
      // 返回 false 时条目自动弹回原位，不会真的删。
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete!(),
      child: tile,
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final note = _note;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条现金流水？'),
        content: Text(
          '$_title${note.isEmpty ? '' : ' · $note'}\n'
          '${fmtDate(txn.date)}　'
          '${txn.amount >= 0 ? '+' : '-'}${fmtMoney(txn.amount.abs())}\n\n'
          '删除后余额会跟着变，且无法撤销。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD93A3A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 「自动」小标：说明这条流水是交易联动生成的，不能在现金页删
class _AutoTag extends StatelessWidget {
  const _AutoTag();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('自动',
          style: TextStyle(fontSize: 10, color: primary, height: 1.4)),
    );
  }
}
