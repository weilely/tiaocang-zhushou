import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/securities_source.dart';
import '../logic/holding_import.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';
import 'widgets/cn_date_picker.dart';

/// 期初持仓导入：手工录入 + 拍照/相册 OCR 预填，共用同一张可编辑表格
class HoldingImportPage extends StatefulWidget {
  const HoldingImportPage({super.key, this.initialRows, this.sourceLabel});

  /// OCR 预填的行；为空则是「添加基金」的手工模式
  final List<HoldingImportRow>? initialRows;

  /// 数据来源说明（例如「拍照识别」）
  final String? sourceLabel;

  @override
  State<HoldingImportPage> createState() => _HoldingImportPageState();
}

class _HoldingImportPageState extends State<HoldingImportPage> {
  late List<HoldingImportRow> _rows;
  int? _accountId;
  DateTime _date = DateTime.now();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rows = List.of(widget.initialRows ?? []);
    if (_rows.isEmpty) _rows.add(HoldingImportRow());
    final st = context.read<AppState>();
    _accountId = st.accountFilter ??
        (st.accounts.isNotEmpty ? st.accounts.first.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final valid = _rows.where((r) => r.valid).toList();
    final problems = _rows.where((r) => !r.isBlank && !r.valid).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('期初持仓导入'),
        actions: [
          IconButton(
            tooltip: '添加一行',
            onPressed: () => setState(() => _rows.add(HoldingImportRow())),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 32),
        children: [
          if (widget.sourceLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('数据来源：${widget.sourceLabel}，请逐行核对后再导入',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
            ),
          SectionCard(
            title: '建仓信息',
            child: Column(
              children: [
                DropdownButtonFormField<int>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(labelText: '账户'),
                  items: [
                    for (final a in state.accounts)
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => _accountId = v),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(10),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '建仓日期',
                      suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                    ),
                    child: Text(fmtDateCn(_date)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '每一行会生成一笔「买入」流水（备注：期初持仓），成本按你填的成本单价计。',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          for (var i = 0; i < _rows.length; i++) _rowCard(context, state, i),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() => _rows.add(HoldingImportRow())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加一行'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: (_busy || valid.isEmpty) ? null : () => _import(state, valid),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(problems > 0
                ? '导入 ${valid.length} 笔（$problems 行有问题已跳过）'
                : '导入 ${valid.length} 笔'),
          ),
        ],
      ),
    );
  }

  /// 字段的输入框装饰：识别推断出来的字段挂个 ⚠，提示核对
  InputDecoration _dec(String label, {bool weak = false}) => InputDecoration(
        labelText: label,
        suffixIcon: weak
            ? const Tooltip(
                message: '识别推断出来的，请核对',
                child: Icon(Icons.error_outline, size: 16, color: Color(0xFFB4770A)),
              )
            : null,
      );

  Widget _rowCard(BuildContext context, AppState state, int i) {
    final r = _rows[i];
    final issue = r.isBlank ? null : r.validate();
    final amount = r.amount;

    return SectionCard(
      title: '第 ${i + 1} 行${r.matched ? '' : (r.code.isEmpty ? '' : '（未匹配）')}'
          '${r.needsReview ? ' · 有 ${r.weak.length} 处需核对' : ''}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: r.confirmed ? '已确认（点一下取消）' : '确认这一行',
            icon: Icon(
              r.confirmed ? Icons.check_circle : Icons.check_circle_outline,
              size: 20,
              color: r.confirmed ? const Color(0xFF1A9C5B) : null,
            ),
            onPressed: () => setState(() => r.confirmed = !r.confirmed),
          ),
          IconButton(
            tooltip: '删除这一行',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _rows.removeAt(i)),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.rawText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('识别原文：${r.rawText}',
                  style: TextStyle(
                      fontSize: 10, color: Theme.of(context).hintColor, height: 1.4)),
            ),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: r.code,
                  decoration: _dec('代码', weak: r.weak.contains('code')),
                  onChanged: (v) => setState(() => r.code = v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '在基础数据库里查',
                icon: const Icon(Icons.search, size: 18),
                onPressed: () => _lookup(state, r),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: r.name,
            decoration: _dec('名称', weak: r.weak.contains('name')),
            onChanged: (v) => setState(() => r.name = v.trim()),
          ),
          if (r.candidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('模糊匹配到这些标的，点一个确认（也可以自己搜）',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cand in r.candidates)
                  ActionChip(
                    avatar: const Icon(Icons.check, size: 14),
                    label: Text(
                      '${cand.name.isEmpty ? cand.code : cand.name}（${cand.code}）',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: () => setState(() {
                      r.code = cand.code;
                      r.name = cand.name;
                      r.kind = cand.assetKind;
                      r.market = cand.market;
                      r.matched = true;
                      r.weak.removeAll(['code', 'name']);
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: r.shares == null ? '' : _trim(r.shares!),
                  decoration: _dec('份额 / 股数', weak: r.weak.contains('shares')),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) =>
                      setState(() => r.shares = double.tryParse(v.trim())),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  initialValue: r.costPrice == null ? '' : _trim(r.costPrice!),
                  decoration:
                      _dec('成本单价', weak: r.weak.contains('costPrice')),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) =>
                      setState(() => r.costPrice = double.tryParse(v.trim())),
                ),
              ),
            ],
          ),
          if (r.needsReview)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('带 ⚠ 的字段是识别推断出来的，导入前扫一眼',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor)),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('标的类型',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              const SizedBox(width: 10),
              DropdownButton<AssetKind>(
                value: r.kind,
                isDense: true,
                items: [
                  for (final k in AssetKind.values)
                    DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: (v) => setState(() => r.kind = v ?? AssetKind.fund),
              ),
              const Spacer(),
              if (amount != null)
                Text('金额 ${fmtMoney(amount)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          if (r.existingShares != null && r.existingShares! > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('该账户已有 ${fmtShares(r.existingShares!)} 份，导入后会累加',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFB4770A))),
            ),
          if (issue != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(issue,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFD93A3A))),
            ),
        ],
      ),
    );
  }

  static String _trim(double v) {
    var s = v.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  Future<void> _pickDate() async {
    final picked = await showCnDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  /// 用基础数据库补全代码/名称/类型
  Future<void> _lookup(AppState state, HoldingImportRow r) async {
    final kw = r.code.isNotEmpty ? r.code : r.name;
    if (kw.isEmpty) return;
    setState(() => _busy = true);
    final res = await state.searchAssets(kw, limit: 5);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没找到，可先去「设置 → 数据维护中心」更新基础数据')),
      );
      return;
    }
    final r0 = res.rows.first;
    setState(() {
      r.code = r0.code;
      r.name = r0.name;
      r.kind = r0.assetKind;
      r.market = r0.market;
      r.category = assetCategoryFor(r0);
      r.matched = true;
    });
  }

  Future<void> _import(AppState state, List<HoldingImportRow> valid) async {
    if (_accountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择账户')),
      );
      return;
    }
    if (!isValidOpenDate(_date)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('建仓日期不能晚于今天')),
      );
      return;
    }

    setState(() => _busy = true);
    var done = 0;
    for (final r in valid) {
      final asset = await state.ensureAsset(r.toAsset());
      final txn = r.toTxn(
        accountId: _accountId!,
        assetId: asset.id!,
        date: _date,
      );
      await state.saveTxnWithAsset(txn, asset);
      done++;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入 $done 笔期初持仓')),
    );
  }
}
