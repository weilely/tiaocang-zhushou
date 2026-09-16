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

  bool get deletable => onDelete != null && !isAuto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = txn.amount >= 0;
    final color = txn.isIncome
        ? const Color(0xFFB4770A)
        : (positive ? const Color(0xFFD93A3A) : const Color(0xFF1A9C5B));

    final tile = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Row(
        children: [
          Text(txn.typeLabel,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (isAuto) ...[
            const SizedBox(width: 6),
            const _AutoTag(),
          ],
        ],
      ),
      subtitle: Text(
        '${fmtDate(txn.date)}${accountName.isEmpty ? '' : ' · $accountName'}'
        '${txn.note.isEmpty ? '' : ' · ${txn.note}'}'
        '${isAuto ? ' · 随交易自动记，请到交易记录里删' : ''}',
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
      onDismissed: (_) => onDelete!(),
      child: tile,
    );
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
