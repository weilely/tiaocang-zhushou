import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
import '../logic/cash_flow.dart';
import '../state/app_state.dart';
import 'txn_edit_page.dart';
import 'widgets/cash_txn_tile.dart';
import 'widgets/common.dart';
import 'widgets/cn_date_picker.dart';
import 'widgets/segmented_pills.dart';

/// 现金管理：只针对**当前账户**（总览标题栏选定），余额 = Σ流水金额
///
/// 现金的当月/累计收益、累计分红只在这一页显示；总览不显示。
///
/// **抬头口径（用户 2026-09-29）**：`充值 / 提现 / 收益 / 买入 / 卖出 /
/// 分红 / 定投 / 再投` —— 上一条筛选条就是这几个（「定投」是买入里带定投标记的、
/// 「再投」是红利再投那条 0 元行），旧的「调整」手工入口已按他的口径去掉
/// （老数据里的调整流水仍能显示、能编辑）。
///
/// 这一页还负责两件事：
/// - **筛选**：类型筛选条 + 「只看我记的」开关（把交易自动生成的行隐掉）；
/// - **编辑**：手记的流水点一下就能改；联动生成的不能改，给一条
///   「去改那笔交易」的路 —— 单独改影子会让现金余额与交易对不上。
class CashManagePage extends StatefulWidget {
  const CashManagePage({super.key});

  @override
  State<CashManagePage> createState() => _CashManagePageState();
}

class _CashManagePageState extends State<CashManagePage> {
  final Set<int> _openYears = {};
  final Set<String> _openMonths = {};
  bool _initialized = false;

  /// 类型筛选：'all' 或 `CashType` 里的种类（含显示分类 'dca'）
  String _kind = 'all';

  /// 只看我记的：把交易自动生成的行（买入/卖出/分红/定投/再投）隐掉
  bool _onlyMine = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final now = DateTime.now();
      _openYears.add(now.year);
      _openMonths.add('${now.year}-${now.month}');
      _initialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final isAll = st.accountFilter == null;
    final mine = st.cashTxns
        .where((t) => isAll || t.accountId == st.accountFilter)
        .toList();

    final list = <CashTxn>[];
    var autoCount = 0;
    for (final t in mine) {
      if (t.srcTxnId != null) autoCount++;
      if (_onlyMine && t.srcTxnId != null) continue;
      if (_kind != 'all' && cashRowKind(t, st.linkedTxnOf(t)) != _kind) continue;
      list.add(t);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('现金管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 32),
        children: [
          _balanceCard(context, st, isAll),
          if (isAll)
            _hint(context, '当前是「全部账户」，只能查看合计。要记录现金变动，请先在首页标题栏选择一个账户。')
          else
            _hint(context, '现金按账户记账；买入/卖出/分红会自动写入这个账户，不用手动补'
                '（红利再投因不动现金，只记一条 0 元的「再投」行）。'),
          _filterBar(context, mine.length, autoCount),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 30),
              child: EmptyHint(
                icon: Icons.account_balance_wallet_outlined,
                text: mine.isEmpty
                    ? '还没有现金记录\n用上面的按钮记一笔充值'
                    : '这个筛选下没有记录',
              ),
            )
          else
            ..._grouped(context, st, list, isAll),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, color: Theme.of(context).hintColor, height: 1.5)),
      );

  // ---------------- 筛选条（类型 + 只看我记的） ----------------

  Widget _filterBar(BuildContext context, int total, int autoCount) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PillGroup(
            items: [
              for (final k in ['all', ...CashType.filterOrder])
                (
                  label: cashKindLabel(k),
                  selected: _kind == k,
                  onTap: () => setState(() => _kind = k),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            value: _onlyMine,
            onChanged: (v) => setState(() => _onlyMine = v),
            title: const Text('只看我记的', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              autoCount == 0
                  ? '当前 $total 笔都是你自己记的'
                  : '隐藏 $autoCount 笔自动生成的行',
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 余额 + 三个动作 ----------------

  Widget _balanceCard(BuildContext context, AppState st, bool isAll) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('现金余额',
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
                if (!isAll) ...[
                  const SizedBox(width: 8),
                  Text(st.accountsById[st.accountFilter!]?.name ?? '',
                      style: TextStyle(fontSize: 12, color: theme.hintColor)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(fmtMoney(st.cashTotal),
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: st.cashTotal < 0 ? const Color(0xFF1A9C5B) : null,
                )),
            if (st.cashTotal < 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('现金为负：通常是买入扣款多于已记录的充值',
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                _action(context, Icons.add, '充值', CashType.deposit, true),
                const SizedBox(width: 8),
                _action(context, Icons.remove, '提现', CashType.withdraw, true),
                const SizedBox(width: 8),
                _action(context, Icons.savings_outlined, '收益', CashType.income, true),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: _incomeTile(context, '当月收益', st.cashMonthIncome),
                ),
                Expanded(
                  child: _incomeTile(context, '累计收益', st.cashTotalIncome),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _incomeTile(context, '累计分红', st.cashTotalDividend),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '「收益」只算货币基金/国债逆回购的利息；现金分红单列在这里'
              '（记为「分红」入账，不算收益）。',
              style: TextStyle(fontSize: 11, color: theme.hintColor, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incomeTile(BuildContext context, String label, double v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          const SizedBox(height: 3),
          Text(fmtMoneySigned(v),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: v > 0
                    ? const Color(0xFFD93A3A)
                    : (v < 0 ? const Color(0xFF1A9C5B) : null),
              )),
        ],
      );

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    String type,
    bool enabled,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: Material(
        color: enabled ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: enabled ? () => _record(st: context.read<AppState>(), type: type) : null,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Column(
              children: [
                Icon(icon,
                    size: 19, color: enabled ? color : Theme.of(context).disabledColor),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: enabled ? color : Theme.of(context).disabledColor,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 年月折叠流水 ----------------

  List<Widget> _grouped(
      BuildContext context, AppState st, List<CashTxn> list, bool isAll) {
    final byYear = <int, Map<int, List<CashTxn>>>{};
    for (final t in list) {
      (byYear[t.date.year] ??= {}).putIfAbsent(t.date.month, () => []).add(t);
    }
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return [
      for (final y in years) ...[
        _yearHeader(context, y, byYear[y]!),
        if (_openYears.contains(y))
          for (final m in (byYear[y]!.keys.toList()..sort((a, b) => b.compareTo(a))))
            _monthBlock(context, st, y, m, byYear[y]![m]!, isAll),
      ],
    ];
  }

  Widget _yearHeader(BuildContext context, int year, Map<int, List<CashTxn>> months) {
    final all = months.values.expand((e) => e).toList();
    final income = all.where((t) => t.isIncome).fold<double>(0, (a, t) => a + t.amount);
    final dividend =
        all.where((t) => t.type == CashType.dividend).fold<double>(0, (a, t) => a + t.amount);
    final open = _openYears.contains(year);
    return InkWell(
      onTap: () => setState(() {
        if (open) {
          _openYears.remove(year);
        } else {
          _openYears.add(year);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right,
                size: 18, color: Theme.of(context).hintColor),
            const SizedBox(width: 4),
            Text('$year 年',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('${all.length} 笔',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
            const Spacer(),
            if (income > 0)
              Text('收益 ${fmtCompact(income)}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFB4770A))),
            if (dividend > 0) ...[
              if (income > 0) const SizedBox(width: 8),
              Text('分红 ${fmtCompact(dividend)}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFD93A3A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _monthBlock(BuildContext context, AppState st, int year, int month,
      List<CashTxn> list, bool isAll) {
    final key = '$year-$month';
    final open = _openMonths.contains(key);
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Column(
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
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                      size: 16, color: Theme.of(context).hintColor),
                  const SizedBox(width: 4),
                  Text('${month.toString().padLeft(2, '0')} 月',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Text('${list.length} 笔',
                      style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
                ],
              ),
            ),
          ),
          if (open)
            Card(
              margin: const EdgeInsets.only(left: 18, bottom: 8),
              elevation: 0,
              color: Theme.of(context).cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [for (final t in list) _row(context, st, t, isAll)],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AppState st, CashTxn t, bool isAll) {
    // 由买入/卖出/分红/定投联动生成的那条流水**不在这里删**：
    // 它是交易的影子，单独删掉会让现金余额与交易对不上。
    // 要删就去删那笔交易，联动流水会跟着一起走 —— 所以这里不给删除回调。
    // 显示用的标的短名与「是不是定投」都**从影子交易现取**，不吃现金行备注 ——
    // 备注是写入时烘死的，老数据里可能没有「定投」、简称也缺失（实测用户的 463 条
    // 现金行里 0 条备注含「定投」，而对应的影子交易有 339 条是定投）。
    final linked = st.linkedTxnOf(t);
    return CashTxnTile(
      txn: t,
      linkedTxn: linked,
      shortName: st.cashShortOf(t),
      accountName: isAll ? '' : (st.accountsById[t.accountId]?.name ?? ''),
      onDelete: t.srcTxnId != null ? null : () => st.removeCashTxn(t.id!),
      onTap: () => _tapRow(st, t, linked),
    );
  }

  /// 点一行：手记的进编辑；联动生成的给一条「去改那笔交易」的路。
  Future<void> _tapRow(AppState st, CashTxn t, Txn? linked) async {
    if (t.srcTxnId == null) {
      await _record(st: st, type: t.type, existing: t);
      return;
    }
    if (linked == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('这条是交易自动生成的现金流水，请到「全部交易」里改那笔交易'),
      ));
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这条是自动生成的'),
        content: Text(
          '它来自一笔「${linked.type.label}」，改这里会跟交易对不上。\n\n'
          '去改那笔交易，现金流水会跟着一起变。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去改那笔交易'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TxnEditPage(existing: linked)),
    );
  }

  // ---------------- 记一笔 / 改一笔 ----------------

  Future<void> _record({
    required AppState st,
    required String type,
    CashTxn? existing,
  }) async {
    // 「全部账户」下也要能记账：默认落到第一个账户，避免点了没反应
    final accountId = existing?.accountId ??
        st.accountFilter ??
        (st.accounts.isEmpty ? null : st.accounts.first.id);
    if (accountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置里添加一个账户')),
      );
      return;
    }

    final amount = TextEditingController(
        text: existing == null || existing.amount == 0
            ? ''
            : existing.amount.abs().toStringAsFixed(2));
    final note = TextEditingController(text: existing?.note ?? '');
    final principal = TextEditingController();
    final rate = TextEditingController();
    final days = TextEditingController(text: '30');
    // 关联基金（可选）：选了就把简称写进备注，现金流水一眼看清。
    // **编辑时不提供**：备注里可能早就带着简称，再拼一次会重复。
    var pickedAsset = '';
    var date = existing?.date ?? DateTime.now();
    // 老数据里可能有已去掉手工入口的「调整」，编辑时也让它选得中
    final typeOptions = <String>[
      ...CashType.manualTypes,
      if (existing != null && !CashType.manualTypes.contains(existing.type))
        existing.type,
    ];
    var editType = existing?.type ?? type;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 收益快填：本金 × 年化 × 天数 / 365
          void calc() {
            final p = double.tryParse(principal.text.trim()) ?? 0;
            final r = double.tryParse(rate.text.trim()) ?? 0;
            final d = double.tryParse(days.text.trim()) ?? 0;
            if (p > 0 && r != 0 && d > 0) {
              amount.text = (p * r / 100 * d / 365).toStringAsFixed(2);
              setSheet(() {});
            }
          }

          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      existing == null
                          ? CashType.label(editType)
                          : '编辑 · ${CashType.label(editType)}',
                      style:
                          const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  if (existing != null) ...[
                    const SizedBox(height: 12),
                    SegmentedPills<String>(
                      items: [
                        for (final t in typeOptions)
                          (value: t, label: CashType.label(t)),
                      ],
                      selected: editType,
                      onChanged: (v) => setSheet(() => editType = v),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (editType == CashType.income) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: principal,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(labelText: '本金'),
                            onChanged: (_) => calc(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: rate,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration:
                                const InputDecoration(labelText: '年化 %'),
                            onChanged: (_) => calc(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 78,
                          child: TextField(
                            controller: days,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: '天数'),
                            onChanged: (_) => calc(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('按「本金 × 年化 × 天数 ÷ 365」估算，可手工改写下面的金额',
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(ctx).hintColor)),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: amount,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: editType == CashType.adjust ? '金额（可填负数）' : '金额',
                      prefixText: '¥ ',
                    ),
                  ),
                  const SizedBox(height: 14),
                  InkWell(
                    onTap: () async {
                      final picked = await showCnDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                      );
                      if (picked != null) setSheet(() => date = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '日期',
                        suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                      ),
                      child: Text(fmtDateCn(date)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: note,
                    decoration: const InputDecoration(labelText: '备注（可选）'),
                  ),
                  if (existing == null) ...[
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: pickedAsset,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '关联基金（可选，显示简称）',
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('不关联')),
                        for (final a in st.assetList)
                          DropdownMenuItem(
                            value: a.code,
                            child: Text(st.displayShortOf(a.code),
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) => setSheet(() => pickedAsset = v ?? ''),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: () async {
                      final v = double.tryParse(amount.text.trim()) ?? 0;
                      if (v == 0) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('请填写金额')),
                        );
                        return;
                      }
                      final signed = switch (editType) {
                        CashType.deposit => v.abs(),
                        CashType.withdraw => -v.abs(),
                        CashType.income => v.abs(),
                        // 老数据里的「调整」可正可负，原样收
                        _ => v,
                      };
                      if (existing != null) {
                        final ok = await st.updateCashTxn(CashTxn(
                          id: existing.id,
                          accountId: accountId,
                          type: editType,
                          amount: signed,
                          date: date,
                          note: note.text.trim(),
                          createdAt: existing.createdAt,
                        ));
                        if (!ok) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content: Text('这条改不了：它是交易自动生成的'),
                            ));
                          }
                          return;
                        }
                      } else {
                        await st.addCashTxn(CashTxn(
                          accountId: accountId,
                          type: editType,
                          amount: signed,
                          date: date,
                          note: () {
                            final n = note.text.trim();
                            if (pickedAsset.isEmpty) return n;
                            final s = st.displayShortOf(pickedAsset);
                            return n.isEmpty ? s : '$s · $n';
                          }(),
                        ));
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    for (final c in [amount, note, principal, rate, days]) {
      c.dispose();
    }
  }
}
