import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../logic/portfolio.dart';
import '../state/app_state.dart';
import 'dca_plan_sheet.dart';
import 'txn_edit_page.dart';
import 'asset_edit_page.dart';
import 'widgets/common.dart';
import 'widgets/txn_history.dart';

/// 持仓详情（全屏）：顶部是该标的的交易功能，下方是它的交易记录（年/月折叠）
class AssetDetailPage extends StatelessWidget {
  final int accountId;
  final int assetId;

  const AssetDetailPage({
    super.key,
    required this.accountId,
    required this.assetId,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final asset = state.assetsById[assetId];
    final account = state.accountsById[accountId];
    final p = state.positionOf(accountId, assetId);

    if (asset == null || p == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('持仓详情')),
        body: const EmptyHint(
          icon: Icons.search_off,
          text: '这笔持仓已经不存在了',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        actions: [
          IconButton(
            tooltip: '编辑简称 / 关联 / 份额成本',
            icon: const Icon(Icons.drive_file_rename_outline),
            onPressed: () => _edit(context, asset),
          ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              asset.name.isEmpty ? asset.code : asset.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              '${asset.code} · ${asset.kind.label}'
              '${account == null ? '' : ' · ${account.name}'}',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _actionBar(context, asset, p),
          _metricsCard(context, p),
          _historyCard(context, p),
        ],
      ),
    );
  }

  /// 打开「编辑」页（简称 / 关联 ETF / 持仓份额 / 单位成本）
  Future<void> _edit(BuildContext context, Asset asset) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AssetEditPage(accountId: accountId, assetId: asset.id!),
    ));
  }

  Widget _actionBar(BuildContext context, Asset asset, Position p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          _action(context,
              icon: Icons.add_shopping_cart_outlined,
              label: '买入',
              color: const Color(0xFFD93A3A),
              onTap: () => _openTxn(context, TxnType.buy, asset, p)),
          const SizedBox(width: 8),
          _action(context,
              icon: Icons.sell_outlined,
              label: '卖出',
              color: const Color(0xFF1A9C5B),
              onTap: p.isEmpty
                  ? null
                  : () => _openTxn(context, TxnType.sell, asset, p)),
          const SizedBox(width: 8),
          _action(context,
              icon: Icons.event_repeat_outlined,
              label: '定投',
              color: const Color(0xFF1F6FEB),
              onTap: () => _openDca(context, asset, p)),
          const SizedBox(width: 8),
          _action(context,
              icon: Icons.redeem_outlined,
              label: '分红',
              color: const Color(0xFFB4770A),
              onTap: () => _openTxn(context, TxnType.dividend, asset, p)),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Expanded(
      child: Material(
        color: enabled ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(icon,
                    size: 20,
                    color: enabled ? color : Theme.of(context).disabledColor),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: enabled ? color : Theme.of(context).disabledColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 定投：已有计划就打开编辑，没有就新建
  Future<void> _openDca(BuildContext context, Asset asset, Position p) async {
    final plans = context.read<AppState>().dcaPlansFor(p.accountId, asset.id!);
    await showDcaPlanSheet(
      context,
      accountId: p.accountId,
      assetId: asset.id!,
      existing: plans.isEmpty ? null : plans.first,
    );
  }

  Future<void> _openTxn(
    BuildContext context,
    TxnType type,
    Asset asset,
    Position p, {
    String? note,
  }) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TxnEditPage(
        presetAsset: asset,
        presetAccountId: p.accountId,
        presetType: type,
        presetNote: note,
        maxShares: type == TxnType.sell ? p.shares : null,
      ),
    ));
  }

  // ---------------- 概览（精简：只留最常用的几个数） ----------------

  Widget _metricsCard(BuildContext context, Position p) {
    final xirr = p.xirrPct;
    final quote = p.quote;

    Widget cell(String label, String value, {Color? color, String? sub}) =>
        StatTile(label: label, value: value, valueColor: color, sub: sub);

    return SectionCard(
      title: '持仓概览',
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: cell('持有份额',
                      fmtSharesOf(p.shares,
                          isFund: p.asset.kind == AssetKind.fund))),
              Expanded(child: cell('成本单价', fmtPrice(p.avgCost))),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: cell(
                  '最新价',
                  p.hasQuote ? fmtPrice(p.price) : '--',
                  sub: quote == null
                      ? '无行情'
                      : '${quote.priceTypeLabel} ${quote.infoDate}',
                ),
              ),
              Expanded(child: cell('当前市值', fmtMoney(p.marketValue))),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: cell('当日收益', fmtMoneySigned(p.dayPnl),
                    color: pnlColor(p.dayPnl),
                    sub: fmtPctOrNull(p.hasQuote ? p.dayPnlPct : null)),
              ),
              Expanded(
                child: cell('持仓收益', fmtMoneySigned(p.holdingPnl),
                    color: pnlColor(p.holdingPnl),
                    sub: fmtPctOrNull(p.floatingPctOrNull)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: cell('累计收益', fmtMoneySigned(p.cumulativePnl),
                    color: pnlColor(p.cumulativePnl),
                    sub: fmtPct(p.cumulativePct)),
              ),
              Expanded(
                child: cell('实现收益', fmtMoneySigned(p.realized),
                    color: pnlColor(p.realized),
                    sub: '年化 ${xirr.isNaN ? '--' : fmtPct(xirr)}'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 交易记录（按月折叠，页面主体） ----------------

  Widget _historyCard(BuildContext context, Position p) {
    return SectionCard(
      title: '交易记录（${p.txns.length} 笔）',
      child: TxnHistoryList(txns: p.txns, highlightNote: '定投'),
    );
  }
}
