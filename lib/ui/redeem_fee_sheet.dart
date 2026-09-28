import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../logic/redeem_fee.dart';
import '../state/app_state.dart';

/// 打开「卖出费率分布」：按持有天数分档 + 先进先出算出各档的区间份额
///
/// 用户 2026-09-28 发来参考图（中基 App 的同类弹框）＋「得参考基金档案赎回费率」，
/// 随后又要求「**弹出方式像我给你那张图一样，一卡片的方式显示**」——
/// 所以这里用**居中的对话框卡片**（标题 + 表格 + 确定），不是底部弹层。
///
/// 档位**优先取基金档案**（同花顺 `fund/profile/detail` 的 redemption 行，
/// 实测 004814 是 5 档、025497/021362/027858 只有 2 档），用户手动改过就用他的，
/// 都没有才回落到内置默认档 —— 来源在卡片里如实标出来。
Future<void> showRedeemFeeSheet(
  BuildContext context, {
  required int accountId,
  required int assetId,
}) {
  final st = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppState>.value(
      value: st,
      child: _RedeemFeeDialog(accountId: accountId, assetId: assetId),
    ),
  );
}

class _RedeemFeeDialog extends StatefulWidget {
  const _RedeemFeeDialog({required this.accountId, required this.assetId});

  final int accountId;
  final int assetId;

  @override
  State<_RedeemFeeDialog> createState() => _RedeemFeeDialogState();
}

class _RedeemFeeDialogState extends State<_RedeemFeeDialog> {
  bool _loading = true;
  List<RedeemTier> _tiers = kDefaultRedeemTiers;
  String _source = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final st = context.read<AppState>();
    final code = st.assetsById[widget.assetId]?.code ?? '';
    setState(() => _loading = true);
    final r = await st.redeemTiersFor(code, force: force);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _tiers = r.tiers;
      _source = r.source;
      _error = r.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final asset = st.assetsById[widget.assetId];
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    if (asset == null) return const SizedBox.shrink();

    final lots = st.redeemLotsOf(widget.accountId, widget.assetId);
    final allLots = st.redeemLotsOf(widget.accountId, widget.assetId,
        asOf: DateTime.now());
    final sellable = lots.fold<double>(0, (a, l) => a + l.shares);
    final nav = st.navSamples[asset.code]?.isNotEmpty == true
        ? st.navSamples[asset.code]!.last.nav
        : 0.0;
    final rows = tierBreakdown(
        lots: lots, asOf: DateTime.now(), tiers: _tiers);
    final est = nav > 0 && sellable > 0
        ? estimateRedeemFee(
            lots: lots,
            sellShares: sellable,
            date: DateTime.now(),
            nav: nav,
            tiers: _tiers,
          )
        : null;
    // 当天买入的部分 T+1 不能卖，单独说一句（别让人以为少算了份额）
    final locked = allLots.fold<double>(0, (a, l) => a + l.shares) - sellable;

    // 参考图那种卡片：标题 + 表格 + 底部「确定」
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('卖出费率分布',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${asset.name.isEmpty ? asset.code : asset.name} · ${asset.code}',
              style: hint),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    _source.startsWith('基金档案')
                        ? Icons.verified_outlined
                        : _source.startsWith('你手动')
                            ? Icons.edit_outlined
                            : Icons.info_outline,
                    size: 14,
                    color: Theme.of(context).hintColor,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _loading ? '正在取这只基金的赎回档位…' : '档位来源：$_source',
                      style: hint,
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed:
                        _loading ? null : () => _editTiers(st, asset.code),
                    child: const Text('编辑档位', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('（档案没取到：$_error）', style: hint),
                ),
              const SizedBox(height: 4),
              _table(context, rows, sellable, nav, est?.fee),
              if (locked > 1e-9) ...[
                const SizedBox(height: 8),
                Text(
                  '另有 ${fmtSharesOf(locked, isFund: true)} 份是今天买入的，T+1 之后才能卖，'
                  '没有算进上面的分布与费用估算。',
                  style: hint,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '算法：按先进先出把份额分到各档（先买的先卖），'
                '费用 = Σ（命中份额 × 当日净值 × 该档费率）。'
                '只用来估算赎回费，不影响持仓成本口径（仍是平均成本法）。',
                style: hint,
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _table(BuildContext context, List<({RedeemTier tier, double shares})> rows,
      double sellable, double nav, double? fee) {
    final theme = Theme.of(context);
    final head = TextStyle(
        fontSize: 12, color: theme.hintColor, fontWeight: FontWeight.w600);
    final cell = const TextStyle(fontSize: 13);
    return Column(
      children: [
        Row(
          children: [
            Expanded(flex: 4, child: Text('持有天数', style: head)),
            Expanded(
                flex: 4,
                child:
                    Text('区间份额', style: head, textAlign: TextAlign.right)),
            Expanded(
                flex: 3,
                child: Text('卖出费率', style: head, textAlign: TextAlign.right)),
          ],
        ),
        const Divider(height: 14),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(flex: 4, child: Text(r.tier.label, style: cell)),
                Expanded(
                  flex: 4,
                  child: Text(
                    fmtSharesOf(r.shares, isFund: true),
                    style: cell,
                    textAlign: TextAlign.right,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '${r.tier.ratePct.toStringAsFixed(2)}%',
                    style: cell,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 14),
        Row(
          children: [
            const Expanded(flex: 4, child: Text('可卖合计', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            Expanded(
              flex: 4,
              child: Text(fmtSharesOf(sellable, isFund: true),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.right),
            ),
            const Expanded(flex: 3, child: SizedBox()),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            fee == null
                ? '（拿不到最新净值，暂时算不出预计赎回费）'
                : '若把可卖的 ${fmtSharesOf(sellable, isFund: true)} 份全卖掉：'
                    '预计赎回费约 ${fmtYuan(fee)}（按净值 ${fmtPrice(nav)}）',
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ),
      ],
    );
  }

  /// 编辑档位：只改费率，区间保持（与档案/默认一致）；也可以「恢复跟随档案」
  Future<void> _editTiers(AppState st, String code) async {
    final ctrls = [for (final t in _tiers) TextEditingController(text: _rateText(t.ratePct))];
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('赎回费率档位'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('改的是**费率（%）**，持有天数区间沿用当前档位。',
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor)),
              const SizedBox(height: 10),
              for (var i = 0; i < _tiers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Text(_tiers[i].label,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: ctrls[i],
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              isDense: true, suffixText: '%'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await st.setUserRedeemTiers(code, null);
              if (ctx.mounted) Navigator.pop(ctx, false);
            },
            child: const Text('恢复跟随档案'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final tiers = [
      for (var i = 0; i < _tiers.length; i++)
        _tiers[i].copyWith(ratePct: double.tryParse(ctrls[i].text.trim()) ?? _tiers[i].ratePct),
    ];
    for (final c in ctrls) {
      c.dispose();
    }
    if (saved != true || !mounted) return;
    await st.setUserRedeemTiers(code, tiers);
    await _load();
  }

  static String _rateText(double v) {
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }
}
