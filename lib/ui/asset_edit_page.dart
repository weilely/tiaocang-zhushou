import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/securities_repo.dart';
import '../logic/link_etf.dart';
import '../state/app_state.dart';

/// 基金详情「编辑」页：从详情页右上角铅笔图标进入
///
/// 汇总四个可改的东西（原来分散在调仓页的「关联 ETF」、现金流水的「简称」，
/// 以及新增的手改「持仓份额 / 单位成本」）：
/// 1. 简称（现金流水里显示）
/// 2. 关联 ETF（场外基金没有实时行情，用它估算当日涨幅）
/// 3. 持仓份额：直接改当前份额 → 记一笔「持仓调整」买卖流水（买多退少）
/// 4. 单位成本：改成本单价（份额不变）→ 把成本总额差值记一笔「成本调整」流水
///
/// 份额 / 成本都通过记流水落地（不改历史流水），改完立即刷新所有派生数据。
class AssetEditPage extends StatefulWidget {
  final int accountId;
  final int assetId;

  const AssetEditPage({
    super.key,
    required this.accountId,
    required this.assetId,
  });

  @override
  State<AssetEditPage> createState() => _AssetEditPageState();
}

class _AssetEditPageState extends State<AssetEditPage> {
  final _shortCtrl = TextEditingController();
  final _sharesCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  bool _saving = false;
  String? _saveError;

  // 关联 ETF 搜索（同调仓页口径：场内 ETF）
  final _linkCtrl = TextEditingController();
  List<SecurityRow> _linkRows = const [];
  bool _linkSearching = false;
  String? _linkError;

  String? get _currentLink =>
      context.read<AppState>().assetsById[widget.assetId]?.linkCode.trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final st = context.read<AppState>();
      final asset = st.assetsById[widget.assetId];
      if (asset == null) return;
      _shortCtrl.text = st.assetShortOf(asset.code);
      _linkCtrl.text = asset.linkCode;
      final p = st.positionOf(widget.accountId, widget.assetId);
      if (p != null) {
        _sharesCtrl.text = _numText(p.shares);
        _costCtrl.text = _numText(p.avgCost);
      }
      if (_linkCtrl.text.trim().isNotEmpty) {
        _searchLink(_linkCtrl.text);
      }
    });
  }

  @override
  void dispose() {
    _shortCtrl.dispose();
    _sharesCtrl.dispose();
    _costCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  static String _numText(double v) {
    if (v == 0) return '0';
    var s = v.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  Future<void> _searchLink(String kw) async {
    if (kw.trim().isEmpty) {
      if (mounted) setState(() => _linkRows = const []);
      return;
    }
    setState(() {
      _linkSearching = true;
      _linkError = null;
    });
    final st = context.read<AppState>();
    final res = await st.searchAssets(kw, allowRemote: true);
    if (!mounted) return;
    setState(() {
      _linkSearching = false;
      _linkError = res.error;
      _linkRows = res.rows.where((r) => isExchangeEtfCode(r.code)).toList();
    });
  }

  Future<void> _save() async {
    final st = context.read<AppState>();
    final asset = st.assetsById[widget.assetId];
    if (asset == null) return;
    final p = st.positionOf(widget.accountId, widget.assetId);

    final wantShares = double.tryParse(_sharesCtrl.text.trim()) ?? 0;
    final wantCost = double.tryParse(_costCtrl.text.trim()) ?? 0;

    // 校验
    if (p != null && p.shares > 0) {
      if (wantShares <= 0) {
        setState(() => _saveError = '持仓份额必须大于 0');
        return;
      }
      if (wantCost <= 0) {
        setState(() => _saveError = '单位成本必须大于 0');
        return;
      }
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      // 1) 简称（资产级，直接落库）
      await st.setAssetShort(asset.code, _shortCtrl.text.trim());

      // 2) 份额 / 成本：通过「调整」流水落地（不改历史流水）
      if (p != null && p.shares > 0) {
        final oldShares = p.shares;
        final oldAvg = p.avgCost; // 旧成本单价

        // 份额变了 → 按旧成本补一笔「持仓调整」买卖流水
        if ((wantShares - oldShares).abs() > 1e-9) {
          final delta = wantShares - oldShares;
          await st.saveTxnAndLinkedCash(Txn(
            accountId: widget.accountId,
            assetId: widget.assetId,
            type: delta > 0 ? TxnType.buy : TxnType.sell,
            date: DateTime.now(),
            amount: delta.abs() * oldAvg,
            shares: delta.abs(),
            price: oldAvg,
            fee: 0,
            note: '持仓调整',
          ));
        }

        // 成本单价变了 → 把「(新单价-旧单价) × 新份额」记成「成本调整」流水
        // （shares=0 的流水不动份额、只动成本投入；方向：调高=买入、调低=卖出）
        final sharesAfter =
            (wantShares - oldShares).abs() > 1e-9 ? wantShares : oldShares;
        if ((wantCost - oldAvg).abs() > 1e-9) {
          final diff = (wantCost - oldAvg) * sharesAfter;
          await st.saveTxnNoCash(Txn(
            accountId: widget.accountId,
            assetId: widget.assetId,
            type: diff > 0 ? TxnType.buy : TxnType.sell,
            date: DateTime.now(),
            amount: diff.abs(),
            shares: 0,
            price: 0,
            fee: 0,
            note: '成本调整',
          ));
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '保存失败：$e';
      });
    }
  }

  Widget _sectionCard(BuildContext context,
      {required IconData icon,
      required String title,
      required String? subtitle,
      required Widget child}) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(subtitle,
                    style: TextStyle(
                        fontSize: 11, color: theme.hintColor, height: 1.5)),
              ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final asset = st.assetsById[widget.assetId];
    final p = st.positionOf(widget.accountId, widget.assetId);

    if (asset == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑持仓')),
        body: const Center(child: Text('标的已不存在')),
      );
    }

    final curLink = _currentLink ?? '';
    final linked = curLink.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Text('编辑 · ${asset.name.isEmpty ? asset.code : asset.name}',
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存全部',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          // 1) 简称
          _sectionCard(
            context,
            icon: Icons.drive_file_rename_outline,
            title: '基金简称',
            subtitle: '现金流水、持仓卡片里显示它；留空即使用标的名称',
            child: TextField(
              controller: _shortCtrl,
              decoration: const InputDecoration(
                hintText: '例如：价值100',
                isDense: true,
              ),
            ),
          ),
          // 2) 关联 ETF
          _sectionCard(
            context,
            icon: Icons.link,
            title: '关联 ETF',
            subtitle:
                '场外基金没有实时行情，预估涨幅 / 预估收益用它来算；场内标的可以留空。点列表项即选中，再点一次取消。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _linkCtrl,
                  autofocus: false,
                  decoration: InputDecoration(
                    labelText: 'ETF 代码 / 名称',
                    hintText: '如 510300、沪深300ETF',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    Future.delayed(const Duration(milliseconds: 350), () {
                      if (_linkCtrl.text.trim() == v.trim()) {
                        _searchLink(v);
                      }
                    });
                  },
                ),
                const SizedBox(height: 6),
                if (_linkSearching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_linkError != null)
                  Text('联网搜索失败，可先去「设置 → 数据维护中心」更新基础数据',
                      style:
                          TextStyle(fontSize: 11, color: Theme.of(context).hintColor))
                else if (_linkRows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('没有匹配的内场 ETF',
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(context).hintColor)),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _linkRows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = _linkRows[i];
                        final selected = r.code == curLink;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(r.name,
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: selected
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                            : null)),
                              ),
                              if (selected)
                                const Icon(Icons.check_circle,
                                    size: 18, color: Color(0xFF1F6FEB)),
                            ],
                          ),
                          subtitle: Text(r.subtitle,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).hintColor)),
                          onTap: () => st.setAssetLink(
                              widget.assetId, selected ? '' : r.code),
                        );
                      },
                    ),
                  ),
                if (linked)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => st.setAssetLink(widget.assetId, ''),
                      child: const Text('清除关联'),
                    ),
                  ),
              ],
            ),
          ),
          // 3) 持仓份额 / 4) 单位成本
          _sectionCard(
            context,
            icon: Icons.tune,
            title: '持仓份额 / 单位成本',
            subtitle: p == null
                ? '该账户下还没有持仓，无法修改'
                : '保存时记一笔「持仓调整」流水（不改动历史流水）。当前：份额 ${fmtShares(p.shares)}、成本 ${fmtPrice(p.avgCost)}',
            child: p == null
                ? Text('暂无持仓',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
                : Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _sharesCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: '持仓份额',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _costCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: '单位成本',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_saveError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_saveError!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFD93A3A))),
            ),
        ],
      ),
    );
  }
}
