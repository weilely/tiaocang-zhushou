import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/dca_models.dart';
import '../data/models.dart';
import '../data/securities_repo.dart';
import '../logic/dca.dart';
import '../state/app_state.dart';
import 'widgets/cn_date_picker.dart';

/// 定投计划的创建 / 编辑弹层
///
/// 目标标的两种给法（二选一）：
/// - [assetId]：库里已有这个标的（从持仓列表、详情页进来）；
/// - [pendingRow]：**搜索结果里还没落库的标的**（用户 2026-09-29 要的搜索选目标）——
///   到点「保存」时再 `ensureAsset` 落库。这样"搜了一下又取消"不会在库里
///   留下一条没用的空标的（我在模拟器上试出来过这个垃圾行）。
Future<void> showDcaPlanSheet(
  BuildContext context, {
  required int accountId,
  int? assetId,
  SecurityRow? pendingRow,
  DcaPlan? existing,
}) async {
  assert(assetId != null || pendingRow != null || existing != null,
      '要么给已有的 assetId，要么给搜索结果 pendingRow');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _DcaPlanEditor(
        accountId: accountId,
        assetId: assetId,
        pendingRow: pendingRow,
        existing: existing,
      ),
    ),
  );
}

class _DcaPlanEditor extends StatefulWidget {
  final int accountId;

  /// 库里已有的标的 id（和 [pendingRow] 二选一）
  final int? assetId;

  /// 搜索结果（还没落库），保存时才建标的
  final SecurityRow? pendingRow;
  final DcaPlan? existing;

  const _DcaPlanEditor({
    required this.accountId,
    this.assetId,
    this.pendingRow,
    this.existing,
  });

  @override
  State<_DcaPlanEditor> createState() => _DcaPlanEditorState();
}

class _DcaPlanEditorState extends State<_DcaPlanEditor> {
  final _amount = TextEditingController();
  final _feeRate = TextEditingController();
  DcaFrequency _freq = DcaFrequency.monthly;
  int _day = 1;
  late DateTime _start;

  /// 终止日期（null = 不设终止、一直投下去）
  DateTime? _end;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _start = DateTime(_start.year, _start.month, _start.day);
    final st = context.read<AppState>();
    // 搜索结果还没落库 → 用它的代码预填费率；已有标的就直接查
    final code = widget.pendingRow?.code ??
        (widget.assetId == null ? null : st.assetsById[widget.assetId!]?.code);
    final asset =
        widget.assetId == null ? null : st.assetsById[widget.assetId!];
    if (widget.existing != null) {
      final e = widget.existing!;
      _amount.text = e.amount.toStringAsFixed(e.amount == e.amount.roundToDouble() ? 0 : 2);
      _freq = e.frequency;
      _day = e.dayOfPeriod;
      _start = e.startDate;
      _end = e.endDate;
      _note.text = e.note;
      // 0 不预填成 "0"，留空更好填
      _feeRate.text = e.feeRate > 0 ? _trimNum(e.feeRate) : '';
    } else if (code != null && (asset == null || !asset.kind.isExchange)) {
      // 新建场外计划：用**该基金在「记一笔」里设过的申购费率**预填（一处设定、两处用）
      final pct = st.subFeeRateOf(code);
      _feeRate.text = pct == null ? '' : _trimNum(pct);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _feeRate.dispose();
    _note.dispose();
    super.dispose();
  }

  static String _trimNum(double v) {
    var s = v.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// 当前输入算出来的「每期手续费 / 每期实际支出」
  ({double fee, double total}) get _feeNow {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final rate = double.tryParse(_feeRate.text.trim()) ?? 0;
    final fee = dcaFeeFor(amount: amount, feeRatePct: rate);
    return (fee: fee, total: amount + fee);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final asset =
        widget.assetId == null ? null : state.assetsById[widget.assetId!];
    // 搜索结果还没落库 → 直接用它带的名称/代码显示
    final title = asset?.name ?? widget.pendingRow?.name ?? '';
    final code = asset?.code ?? widget.pendingRow?.code ?? '';
    final isEdit = widget.existing != null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isEdit ? '编辑定投计划' : '新建定投计划',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '$title · $code',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 18),

            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '每期金额（元）', prefixText: '¥ '),
            ),
            const SizedBox(height: 16),

            // 每期申购费率：场外申购费跟券商佣金不是一回事，所以**按计划单独填**
            TextField(
              controller: _feeRate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '每期申购费率（%）',
                suffixText: '%',
                helperText: '填 0.1 = 申购费 0.1%；留空或填 0 = 不计手续费',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '每期手续费 ¥${_feeNow.fee.toStringAsFixed(2)}'
              ' · 每期实际支出 ¥${_feeNow.total.toStringAsFixed(2)}'
              '\n（手续费另外加：份额按「每期金额 ÷ 净值」买，现金扣「金额 + 手续费」）',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
            ),
            const SizedBox(height: 14),

            Text('频率', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 6),
            SegmentedButton<DcaFrequency>(
              // 四个段在 400dp + 字体 1.3 下要挤得下 → 用 shortLabel（「两周」而不是「每两周」）
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 6)),
              ),
              segments: [
                for (final f in DcaFrequency.values)
                  ButtonSegment(value: f, label: Text(f.shortLabel)),
              ],
              selected: {_freq},
              onSelectionChanged: (s) => setState(() {
                _freq = s.first;
                if (_freq == DcaFrequency.monthly) {
                  _day = _day.clamp(1, 28);
                } else if (_freq == DcaFrequency.weekly) {
                  _day = _day.clamp(1, 7);
                }
              }),
            ),
            const SizedBox(height: 16),

            if (_freq == DcaFrequency.monthly)
              DropdownButtonFormField<int>(
                initialValue: _day.clamp(1, 28),
                decoration: const InputDecoration(labelText: '每月几号'),
                items: [
                  for (var d = 1; d <= 28; d++)
                    DropdownMenuItem(value: d, child: Text('$d 日')),
                ],
                onChanged: (v) => setState(() => _day = v ?? 1),
              )
            else if (_freq == DcaFrequency.weekly)
              DropdownButtonFormField<int>(
                initialValue: _day.clamp(1, 7),
                decoration: const InputDecoration(labelText: '每周几'),
                items: [
                  for (var d = 1; d <= 7; d++)
                    DropdownMenuItem(
                        value: d,
                        child: Text('周${const ['', '一', '二', '三', '四', '五', '六', '日'][d]}')),
                ],
                onChanged: (v) => setState(() => _day = v ?? 1),
              )
            else if (_freq == DcaFrequency.biweekly)
              Text('自首期起每 14 天一期',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))
            else
              Text('每个自然日一期；周末/休市顺延到之后第一个交易日',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),

            // 起止日期（用户 2026-09-29：「定投设置起始和终止日期」）
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickStart,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '起始日期',
                        suffixIcon:
                            Icon(Icons.calendar_today_outlined, size: 18),
                      ),
                      child: Text(fmtDate(_start)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: _pickEnd,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '终止日期',
                        suffixIcon: _end == null
                            ? const Icon(Icons.event_busy_outlined, size: 18)
                            : IconButton(
                                tooltip: '清除终止日期（一直投下去）',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () => setState(() => _end = null),
                              ),
                      ),
                      child: Text(
                        // 用 `yyyy-MM-dd`：中文长日期在 400dp + 字体 1.3 下会折成两行
                        _end == null ? '不设终止' : fmtDate(_end!),
                        style: _end == null
                            ? TextStyle(
                                color: Theme.of(context).hintColor, fontSize: 14)
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              // 纯文本，别写 Markdown：App 不解析，`**` 会原样显示出来
              '终止日期含当天：过期末不再生新期数（已补记的照旧留着）。'
              '定投日恰逢周末/休市时，顺延到之后第一个交易日、按那天的净值成交。',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（可选）'),
            ),
            const SizedBox(height: 20),

            if (widget.existing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '已补记到 ${widget.existing!.lastRunDate == null ? '（尚未补记）' : fmtDate(widget.existing!.lastRunDate!)}'
                  '\n下次扣款日 ${_nextHint()}',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
                ),
              ),

            Row(
              children: [
                if (widget.existing != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _toggleEnabled,
                      icon: Icon(
                          widget.existing!.enabled
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          size: 18),
                      label: Text(widget.existing!.enabled ? '暂停' : '启用'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '删除计划',
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(isEdit ? '保存' : '保存并补记'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '保存后会立即把漏掉的期数补齐。若某期取不到历史价格，那一期会跳过并在下次打开应用时重试。',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  String _nextHint() {
    final e = widget.existing;
    if (e == null) return '--';
    final d = nextDcaDate(e, DateTime.now());
    return d == null ? '--' : fmtDate(d);
  }

  Future<void> _pickStart() async {
    final picked = await showCnDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _start = picked;
      // 起始日挪到终止日之后 → 终止日跟着走，别留下一个不可能的区间
      if (_end != null && _end!.isBefore(picked)) _end = null;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showCnDatePicker(
      context: context,
      initialDate: _end ?? _start.add(const Duration(days: 365)),
      firstDate: _start,
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      title: '选择终止日期',
    );
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      _snack('请填写每期金额');
      return;
    }
    setState(() => _busy = true);
    final st = context.read<AppState>();
    // 搜索来的标的**到这一步才落库**（取消弹层就不留空标的）
    var targetId = widget.assetId;
    if (targetId == null) {
      final r = widget.pendingRow;
      if (r == null) {
        setState(() => _busy = false);
        _snack('没有选定标的');
        return;
      }
      final created = await st.ensureAsset(Asset(
        code: r.code,
        name: r.name,
        kind: r.assetKind,
        market: r.market,
      ));
      targetId = created.id;
    }
    final plan = (widget.existing ??
            DcaPlan(
              accountId: widget.accountId,
              assetId: targetId!,
              amount: amount,
              frequency: _freq,
              dayOfPeriod: _day,
              startDate: _start,
            ))
        .copyWith(
      amount: amount,
      frequency: _freq,
      dayOfPeriod: _day,
      startDate: _start,
      // 终止日期可以"清空"，所以要用 clearEndDate 显式说（null 只表示"不改"）
      endDate: _end,
      clearEndDate: _end == null,
      note: _note.text.trim(),
      feeRate: (double.tryParse(_feeRate.text.trim()) ?? 0).clamp(0, 100),
    );
    await st.saveDcaPlan(plan);
    final report = await st.runDueDca(manual: true);
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(report.summary), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _toggleEnabled() async {
    final st = context.read<AppState>();
    final e = widget.existing!;
    await st.setDcaEnabled(e.id!, !e.enabled);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个定投计划？'),
        content: const Text('已经生成的定投交易记录不会被删除。', style: TextStyle(fontSize: 13)),
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
    final st = context.read<AppState>();
    await st.deleteDcaPlan(widget.existing!.id!);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
