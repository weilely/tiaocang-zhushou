import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/dca_models.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';
import 'widgets/segmented_pills.dart';
import 'widgets/txn_history.dart';

/// 全部交易（跨标的）：**按标的 / 按日期** 两种看法，默认按标的且**折叠**，
/// 抬头与筛选用的词表和现金流水页一致（买入 / 卖出 / 分红 / 定投 / 再投），
/// 也可以按类型分类看。支持批量删除。
///
/// 用户 2026-09-29 原话：「数据维护中心的全部交易列表默认按标的折叠，提头也和
/// 现金流水一样，可分类查看，按日期查看。」
/// 分组顺序按名称（没名称按代码）；组内按日期倒序。进多选后左侧变勾选框，
/// 底部一条操作栏可以全选 / 删除，删除会连带清掉该笔交易联动生成的现金流水
/// （和单笔删除同一个入口 `AppState.removeTxn`）。
class AllTxnsPage extends StatefulWidget {
  const AllTxnsPage({super.key, this.planId});

  /// 只看**某条定投计划**产生的记录（定投卡片上点「查看记录」进来）。
  /// 用户 2026-09-30：「可以标记哪些定投记录是哪个定投计划产生的，这样就好定位编辑删除了」。
  final int? planId;

  @override
  State<AllTxnsPage> createState() => _AllTxnsPageState();
}

class _AllTxnsPageState extends State<AllTxnsPage> {
  bool _selecting = false;
  final Set<int> _selected = {};

  /// 视图：`asset` = 按标的（默认，**默认全折叠**）｜`date` = 按日期（年月折叠）
  String _view = 'asset';

  /// 类型筛选，词表与现金流水页同一套：全部 / 买入 / 卖出 / 分红 / 定投 / 再投
  String _kind = 'all';

  /// 只看这条计划（来自 [AllTxnsPage.planId]；页内可清掉）
  int? _planId;

  @override
  void initState() {
    super.initState();
    _planId = widget.planId;
  }

  /// 按标的视图里已展开的标的（默认一个都不展开）
  final Set<int> _openGroups = {};

  /// 类型筛选：与现金流水页同一套词表；「定投」是买入里带定投标记的、
  /// 「再投」是红利再投那种买入（判定都是同一处口径）
  bool _matchKind(Txn t) => switch (_kind) {
        'all' => true,
        'dca' =>
          t.type == TxnType.buy && !t.isReinvest && t.note.contains('定投'),
        'reinvest' => t.isReinvest,
        _ => t.type.name == _kind,
      };

  static String _kindLabel(String k) => switch (k) {
        'all' => '全部',
        'buy' => '买入',
        'sell' => '卖出',
        'dividend' => '分红',
        'dca' => '定投',
        'reinvest' => '再投',
        _ => k,
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // 这条计划还在不在（被删了就只按 id 过滤，标题上如实说明）
    DcaPlan? plan;
    for (final p in state.dcaPlans) {
      if (p.id == _planId) {
        plan = p;
        break;
      }
    }
    final list = state.txns
        .where((t) =>
            state.accountFilter == null || t.accountId == state.accountFilter)
        // 只看这条计划产生的记录（定投卡片点「查看记录」进来的）
        .where((t) => _planId == null || t.dcaPlanId == _planId)
        .where(_matchKind)
        .toList();

    // 买入合计**不含不动现金的那些**（红利再投 / 成本调整）：与资金流卡的
    // 「投入金额」同一口径（用户 2026-09-29：「统一口径」）—— 再投是用分红
    // 换来的份额，把它算成"买入"就和投入金额对不上了。
    final bought = list
        .where((t) => t.type == TxnType.buy && !t.isCashless)
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
                // 真机（400dp 宽 + 字体 1.3）下「共 N 笔 · M 只」与
                // 「买入/卖出/费」三个合计**一行放不下**（真数据体检用例逮到
                // 横向溢出 238px）→ 拆成两行，第二行再窄也能缩。
                preferredSize: const Size.fromHeight(54),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('共 ${list.length} 笔 · ${ids.length} 只',
                          style: TextStyle(
                              fontSize: 12, color: Theme.of(context).hintColor)),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                                    fontSize: 12,
                                    color: Theme.of(context).hintColor)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          // 选着的时候不显示筛选条：免得选中范围被中途改掉
          if (!_selecting) _filterBar(context),
          // 「只看某条定投计划」的标注（从定投卡片点「查看记录」进来时）
          if (_planId != null && !_selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
              child: Row(
                children: [
                  Icon(Icons.event_repeat, size: 14,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      plan == null
                          ? '只看定投计划 #$_planId（这条计划已删除）'
                          : '只看定投计划：${plan.dayLabel} · 每期 ${plan.amount.toStringAsFixed(2)} 元'
                              '（${list.length} 笔）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _planId = null),
                    child: const Text('看全部', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: list.isEmpty
                ? EmptyHint(
                    icon: Icons.receipt_long_outlined,
                    text: state.txns.isEmpty
                        ? '还没有交易记录\n去「持仓」页记一笔'
                        : '这个筛选下没有记录',
                  )
                : (_view == 'asset'
                    ? ListView(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        children: [
                          for (final id in ids)
                            _group(context, state, id, groups[id]!, nameOf(id)),
                        ],
                      )
                    // 按日期：年月折叠，标的写在每行副标题里。
                    // key 跟着筛选走：换类型时重建列表，让"最近一个月"按**筛完的**
                    // 那批重新展开（否则筛完可能一行都不显示，只看到月份头）
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        child: TxnHistoryList(
                          key: ValueKey('date-$_kind'),
                          txns: list,
                          showAssetName: true,
                          selectable: _selecting,
                          selectedIds: _selected,
                          onToggle: (t) => setState(() {
                            if (t.id == null) return;
                            if (!_selected.remove(t.id!)) _selected.add(t.id!);
                          }),
                        ),
                      )),
          ),
        ],
      ),
      bottomNavigationBar: _selecting ? _selectBar(context, state, list) : null,
    );
  }

  /// 筛选条：视图（按标的 / 按日期）+ 类型（全部/买入/卖出/分红/定投/再投）
  Widget _filterBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedPills<String>(
              items: const [
                (value: 'asset', label: '按标的'),
                (value: 'date', label: '按日期'),
              ],
              selected: _view,
              onChanged: (v) => setState(() => _view = v),
            ),
            const SizedBox(height: 6),
            PillGroup(
              items: [
                for (final k in const [
                  'all',
                  'buy',
                  'sell',
                  'dividend',
                  'dca',
                  'reinvest',
                ])
                  (
                    label: _kindLabel(k),
                    selected: _kind == k,
                    onTap: () => setState(() => _kind = k),
                  ),
              ],
            ),
          ],
        ),
      );

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
    // 同上：买入小计也不含红利再投 / 成本调整
    final bought = txns
        .where((t) => t.type == TxnType.buy && !t.isCashless)
        .fold<double>(0, (a, t) => a + t.amount);
    final sold = txns
        .where((t) => t.type == TxnType.sell)
        .fold<double>(0, (a, t) => a + t.amount);
    final groupIds = [for (final t in txns) if (t.id != null) t.id!];
    final allIn = groupIds.isNotEmpty && groupIds.every(_selected.contains);
    // 默认折叠：只有点开过的标的才展开（用户 2026-09-29 要求）
    final open = _openGroups.contains(assetId);

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
                  : () => setState(() {
                        if (!_openGroups.remove(assetId)) {
                          _openGroups.add(assetId);
                        }
                      }),
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
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: Icon(
                            open ? Icons.expand_more : Icons.chevron_right,
                            size: 18,
                            color: Theme.of(context).hintColor),
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
            if (open) ...[
              const Divider(height: 4),
              for (final t in txns)
                txnTile(
                  context,
                  t,
                  selectable: _selecting,
                  selected: t.id != null && _selected.contains(t.id),
                  onToggle: () => setState(() {
                    if (t.id == null) return;
                    if (!_selected.remove(t.id!)) _selected.add(t.id!);
                  }),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
