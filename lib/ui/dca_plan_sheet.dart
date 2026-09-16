import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/dca_models.dart';
import '../logic/dca.dart';
import '../state/app_state.dart';
import 'widgets/cn_date_picker.dart';

/// 定投计划的创建 / 编辑弹层
Future<void> showDcaPlanSheet(
  BuildContext context, {
  required int accountId,
  required int assetId,
  DcaPlan? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _DcaPlanEditor(
        accountId: accountId,
        assetId: assetId,
        existing: existing,
      ),
    ),
  );
}

class _DcaPlanEditor extends StatefulWidget {
  final int accountId;
  final int assetId;
  final DcaPlan? existing;

  const _DcaPlanEditor({
    required this.accountId,
    required this.assetId,
    this.existing,
  });

  @override
  State<_DcaPlanEditor> createState() => _DcaPlanEditorState();
}

class _DcaPlanEditorState extends State<_DcaPlanEditor> {
  final _amount = TextEditingController();
  DcaFrequency _freq = DcaFrequency.monthly;
  int _day = 1;
  late DateTime _start;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day);
    if (e != null) {
      _amount.text = e.amount.toStringAsFixed(e.amount == e.amount.roundToDouble() ? 0 : 2);
      _freq = e.frequency;
      _day = e.dayOfPeriod;
      _start = e.startDate;
      _note.text = e.note;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final asset = state.assetsById[widget.assetId];
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
              '${asset?.name ?? ''} · ${asset?.code ?? ''}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 18),

            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '每期金额（元）', prefixText: '¥ '),
            ),
            const SizedBox(height: 16),

            Text('频率', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 6),
            SegmentedButton<DcaFrequency>(
              segments: const [
                ButtonSegment(value: DcaFrequency.weekly, label: Text('每周')),
                ButtonSegment(value: DcaFrequency.biweekly, label: Text('每两周')),
                ButtonSegment(value: DcaFrequency.monthly, label: Text('每月')),
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
            else
              Text('自首期起每 14 天一期',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),

            InkWell(
              onTap: _pickStart,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '首期日期',
                  suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                ),
                child: Text(fmtDateCn(_start)),
              ),
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
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      _snack('请填写每期金额');
      return;
    }
    setState(() => _busy = true);
    final st = context.read<AppState>();
    final plan = (widget.existing ??
            DcaPlan(
              accountId: widget.accountId,
              assetId: widget.assetId,
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
      note: _note.text.trim(),
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
