import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/dca_models.dart';
import '../../data/models.dart';
import '../../logic/cash_flow.dart';
import '../../state/app_state.dart';
import '../txn_edit_page.dart';

/// 交易记录列表：**按月折叠**（默认展开最近一个月），记录之间不留间隔。
///
/// 以前是「年 → 月」两级，年份那一层在这里没有信息量（每条记录自己带完整日期），
/// 所以去掉年份、去掉缩进 —— 一屏能多看几笔。
class TxnHistoryList extends StatefulWidget {
  final List<Txn> txns;

  /// 是否显示标的名称（全部交易页的「按日期」视图需要，详情页不需要）
  final bool showAssetName;

  /// 是否显示账户名
  final bool showAccountName;

  /// 多选（批量删除）用：勾选态 + 点击回调
  final bool selectable;
  final Set<int> selectedIds;
  final void Function(Txn t)? onToggle;

  const TxnHistoryList({
    super.key,
    required this.txns,
    this.showAssetName = false,
    this.showAccountName = false,
    this.selectable = false,
    this.selectedIds = const {},
    this.onToggle,
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
              showAssetName: widget.showAssetName,
              showAccountName: widget.showAccountName,
              selectable: widget.selectable,
              selected: t.id != null && widget.selectedIds.contains(t.id),
              onToggle: widget.onToggle == null ? null : () => widget.onToggle!(t),
            ),
      ],
    );
  }
}

/// 单条交易记录（左滑删除、点击编辑）—— 详情页与全部交易页共用
///
/// **抬头用「动作词」**（买入 / 卖出 / 分红 / 定投 / 再投），与现金流水页同一套词
/// （用户 2026-09-29：「提头也和现金流水一样」）；日期、份额@净值、（按日期视图里的）
/// 标的、账户、备注都在副标题里。判定只有一处：`logic/cash_flow.dart` 的
/// `txnActionWord` —— 别在这里另写一套 `if`。
///
/// [selectable] 为 true 时进入多选：左侧变勾选框、点击是选中而不是编辑，
/// 也不再挂左滑删除（避免和批量删除两套手势打架）。
Widget txnTile(
  BuildContext context,
  Txn t, {
  bool showAssetName = false,
  bool showAccountName = false,
  bool selectable = false,
  bool selected = false,
  VoidCallback? onToggle,
}) {
  final state = context.read<AppState>();
  final asset = state.assetsById[t.assetId];
  final assetName = asset == null
      ? '未知标的'
      : (asset.name.isEmpty ? asset.code : asset.name);
  final accountName = state.accountsById[t.accountId]?.name ?? '';
  // 抬头词：买入 / 卖出 / 分红 / 定投 / 再投（唯一判定在 txnActionWord）
  final word = txnActionWord(t);

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

  // 副标题：日期 · 明细 [· 标的] [· 账户] [· 备注]
  final sub = [
    fmtDate(t.date),
    detail,
    if (showAssetName) assetName,
    if (showAccountName && accountName.isNotEmpty) accountName,
    if (t.note.isNotEmpty) t.note,
  ].join(' · ');

  // 这条是哪条**定投计划**生成的（用户 2026-09-30：「可以标记哪些定投记录是
  // 哪个定投计划产生的，这样就好定位编辑删除了」）。
  // 老记录（这条字段是后加的）没有标记 → 不显示，不假装知道。
  final planId = t.dcaPlanId;
  DcaPlan? plan;
  if (planId != null) {
    for (final p in state.dcaPlans) {
      if (p.id == planId) {
        plan = p;
        break;
      }
    }
  }
  final planTag = planId == null
      ? null
      : (plan == null
          ? '计划已删'
          : '${plan.dayLabel.replaceAll(' ', '')}·${fmtCompact(plan.amount)}');

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
              // 抬头用动作词首字：买 / 卖 / 分 / 定 / 再
              word.substring(0, 1),
              style:
                  TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
    title: Row(
      children: [
        Expanded(
          child: Text(
            // 抬头＝动作词（买入/卖出/分红/定投/再投），与现金流水页一致
            word,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        // 「待确认」：场外基金当天净值没公布时先记的金额，份额等公布后自动补
        if (t.pending)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFB4770A).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text('待确认',
                style: TextStyle(fontSize: 10, color: Color(0xFFB4770A))),
          ),
        // 这条是哪条定投计划生成的（点进去能改/删）
        if (planTag != null)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(planTag,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.primary)),
          ),
      ],
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        sub,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
      ),
    ),
    // 金额 +（有手续费时）费：大字体下这两行比 dense 行高还高（真数据体检用例
    // 逮到纵向溢出 12px）→ 挂个 scaleDown，只有放不下时才缩一点。
    trailing: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${t.type == TxnType.buy ? '-' : '+'}${fmtMoney(t.amount)}',
            style:
                TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
          if (t.fee > 0)
            Text('费 ${fmtMoney(t.fee)}',
                style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor)),
        ],
      ),
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
