import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../txn_edit_page.dart';

/// 交易记录列表：**按月折叠**（默认展开最近一个月），记录之间不留间隔。
///
/// 以前是「年 → 月」两级，年份那一层在这里没有信息量（每条记录自己带完整日期），
/// 所以去掉年份、去掉缩进 —— 一屏能多看几笔。
class TxnHistoryList extends StatefulWidget {
  final List<Txn> txns;

  /// 是否显示标的名称（全部交易页需要，详情页不需要）
  final bool showAssetName;

  /// 是否显示账户名
  final bool showAccountName;

  /// 需要高亮的备注（例如 `定投`）
  final String? highlightNote;

  const TxnHistoryList({
    super.key,
    required this.txns,
    this.showAssetName = false,
    this.showAccountName = false,
    this.highlightNote,
  });

  @override
  State<TxnHistoryList> createState() => _TxnHistoryListState();
}

class _TxnHistoryListState extends State<TxnHistoryList> {
  final Set<String> _openMonths = {};
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _expandDefault();
      _initialized = true;
    }
  }

  /// 默认展开最近一个月
  void _expandDefault() {
    final months = _grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    if (months.isEmpty) return;
    _openMonths.add(months.first);
  }

  /// key = `yyyy-MM`
  Map<String, List<Txn>> get _grouped {
    final m = <String, List<Txn>>{};
    for (final t in widget.txns) {
      final k = '${t.date.year.toString().padLeft(4, '0')}-'
          '${t.date.month.toString().padLeft(2, '0')}';
      (m[k] ??= <Txn>[]).add(t);
    }
    for (final list in m.values) {
      list.sort((a, b) => b.date.compareTo(a.date)); // 月内倒序
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.txns.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text('还没有交易记录',
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
      );
    }

    final grouped = _grouped;
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final k in keys) _monthBlock(context, k, grouped[k]!),
      ],
    );
  }

  /// 月份头：只写「9月」，不带年份（记录自己带完整日期）
  Widget _monthBlock(BuildContext context, String key, List<Txn> list) {
    final open = _openMonths.contains(key);
    final month = int.parse(key.substring(5));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (open) {
              _openMonths.remove(key);
            } else {
              _openMonths.add(key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(open ? Icons.expand_more : Icons.chevron_right,
                    size: 16, color: Theme.of(context).hintColor),
                const SizedBox(width: 2),
                Text('$month 月',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('${list.length} 笔',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        ),
        if (open)
          for (final t in list)
            txnTile(
              context,
              t,
              highlightNote: widget.highlightNote,
            ),
      ],
    );
  }
}

/// 单条交易记录（左滑删除、点击编辑）—— 详情页与全部交易页共用
///
/// [selectable] 为 true 时进入多选：左侧变勾选框、点击是选中而不是编辑，
/// 也不再挂左滑删除（避免和批量删除两套手势打架）。
Widget txnTile(
  BuildContext context,
  Txn t, {
  bool showAssetName = false,
  bool showAccountName = false,
  String? highlightNote,
  bool selectable = false,
  bool selected = false,
  VoidCallback? onToggle,
}) {
  final state = context.read<AppState>();
  final asset = state.assetsById[t.assetId];
  final accountName = state.accountsById[t.accountId]?.name ?? '';
  final isDca = highlightNote != null && t.note.startsWith(highlightNote);

  final color = switch (t.type) {
    TxnType.buy => const Color(0xFFD93A3A),
    TxnType.sell => const Color(0xFF1A9C5B),
    TxnType.dividend => const Color(0xFFB4770A),
  };

  final detail = switch (t.type) {
    TxnType.buy || TxnType.sell =>
      '${fmtSharesOf(t.shares, isFund: asset?.kind == AssetKind.fund)} 份 @ ${fmtPrice(t.price)}',
    TxnType.dividend => '分红到账',
  };

  final tile = ListTile(
    onTap: selectable
        ? onToggle
        : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => TxnEditPage(existing: t)),
            ),
    dense: true,
    visualDensity: const VisualDensity(vertical: -4),
    contentPadding: const EdgeInsets.symmetric(horizontal: 2),
    leading: selectable
        ? Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 22,
            color: selected ? Theme.of(context).colorScheme.primary : null,
          )
        : Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              t.type.label.substring(0, 1),
              style:
                  TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
    title: Row(
      children: [
        Expanded(
          child: Text(
            showAssetName
                ? (asset?.name.isNotEmpty == true
                    ? asset!.name
                    : (asset?.code ?? '未知标的'))
                : '${fmtDate(t.date)} · $detail',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        if (isDca)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF1F6FEB).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text('定投',
                style: TextStyle(fontSize: 10, color: Color(0xFF1F6FEB))),
          ),
      ],
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        showAssetName
            ? '${fmtDate(t.date)} · $detail'
                '${t.note.isNotEmpty ? ' · ${t.note}' : ''}'
            : '${t.note.isEmpty ? t.type.label : t.note}'
                '${showAccountName && accountName.isNotEmpty ? ' · $accountName' : ''}',
        style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
      ),
    ),
    trailing: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${t.type == TxnType.buy ? '-' : '+'}${fmtMoney(t.amount)}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
        ),
        if (t.fee > 0)
          Text('费 ${fmtMoney(t.fee)}',
              style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor)),
      ],
    ),
  );

  if (selectable) return tile;

  return Dismissible(
    key: ValueKey('txn-${t.id}'),
    direction: DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      color: const Color(0xFFD93A3A),
      child: const Icon(Icons.delete_outline, color: Colors.white),
    ),
    confirmDismiss: (_) async {
      return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除这笔记录？'),
              content: Text(
                  '${asset?.displayName ?? ''}\n${t.type.label} ${fmtMoney(t.amount)}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ),
          ) ??
          false;
    },
    onDismissed: (_) => state.removeTxn(t.id!),
    child: tile,
  );
}
