import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/asset_traits.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
import '../logic/benchmark.dart';
import '../logic/period_return.dart';
import '../logic/portfolio.dart';
import '../logic/range_preset.dart';
import '../state/app_state.dart';
import 'dca_plan_sheet.dart';
import 'fund_profile_page.dart';
import 'txn_edit_page.dart';
import 'asset_edit_page.dart';
import 'widgets/asset_value_chart.dart';
import 'widgets/common.dart';
import 'widgets/returns_line_chart.dart';
import 'widgets/segmented_pills.dart';
import 'widgets/txn_history.dart';

/// 持仓详情（全屏）
///
/// 2026-09-23 按用户给的参考图改版：
/// - 顶部保留该标的的交易功能（买入/卖出/定投/分红）
/// - 下面两个**页签**：`资产收益`（参考图那张「总资产/总收益 曲线 + 区间」卡片）
///   与 `业绩走势`（该基金自己的净值走势 + 大盘对照）。
///   **参考图里的「购买渠道」用户明确不要，所以不做** ✓
/// - 「持仓概览」的八个数字**没有删**（参考图上没有它们），继续留在下面；
///   基金档案入口与交易记录也照旧。
class AssetDetailPage extends StatefulWidget {
  final int accountId;
  final int assetId;

  const AssetDetailPage({
    super.key,
    required this.accountId,
    required this.assetId,
  });

  @override
  State<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends State<AssetDetailPage> {
  /// 页签：0 = 资产收益，1 = 业绩走势
  int _tab = 0;

  /// 资产收益卡片里的口径：0 = 总资产，1 = 总收益
  int _metric = 0;

  /// 区间：参考图默认落在「近3月」
  RangePreset _preset = RangePreset.m3;

  /// 参考图底部那四个区间（`今年` 就是图里的"今年以来"）
  static const List<RangePreset> _presets = [
    RangePreset.month,
    RangePreset.m3,
    RangePreset.y1,
    RangePreset.year,
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final asset = state.assetsById[widget.assetId];
    final account = state.accountsById[widget.accountId];
    final p = state.positionOf(widget.accountId, widget.assetId);

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
          _tabBar(context),
          if (_tab == 0)
            _returnsCard(context, state, asset, p)
          else
            _perfCard(context, state, asset),
          _metricsCard(context, p),
          // 基金档案（同花顺详情接口，点进去才拉）：场外基金与场内 ETF/LOF 都有
          if (asset.kind == AssetKind.fund || asset.kind == AssetKind.etf)
            _fundProfileEntry(context, asset),
          _historyCard(context, p),
        ],
      ),
    );
  }

  /// 页签行（参考图最上面那排；**没有「购买渠道」**）
  Widget _tabBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: SegmentedPills<int>(
        items: const [
          (value: 0, label: '资产收益'),
          (value: 1, label: '业绩走势'),
        ],
        selected: _tab,
        onChanged: (v) => setState(() => _tab = v),
      ),
    );
  }

  /// 区间选择（参考图底部那排；沿用项目既有的 `RangePreset` 口径）
  Widget _rangePills(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SegmentedPills<RangePreset>(
        items: [for (final p in _presets) (value: p, label: p.label)],
        selected: _preset,
        onChanged: (v) => setState(() => _preset = v),
        itemPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
    );
  }

  /// 当前区间（四个预设都不依赖 earliest，所以不会返回 null）
  DateRange get _range =>
      resolvePreset(_preset, now: DateTime.now()) ??
      DateRange(shiftMonths(DateTime.now(), -3), DateTime.now());

  // ---------------- 资产收益（参考图那张卡片） ----------------

  Widget _returnsCard(
      BuildContext context, AppState state, Asset asset, Position p) {
    final theme = Theme.of(context);
    final daily = state.assetDailySeries(
      accountId: widget.accountId,
      assetId: widget.assetId,
      range: _range,
    );
    // 总资产 = 当日持仓市值；总收益 = 累计收益（都来自同一条逐日序列）
    final points = <ValuePoint>[
      for (final d in daily)
        (date: d.date, value: _metric == 0 ? d.marketValue : d.cumPnl),
    ];
    final last = points.isEmpty ? null : points.last.value;
    final lineColor = _metric == 0
        ? theme.colorScheme.primary
        : (last == null ? theme.hintColor : pnlColor(last));
    final label = _metric == 0 ? '总资产' : '总收益';
    final current = last == null
        ? '--'
        : (_metric == 0 ? fmtMoney(last) : fmtMoneySigned(last));

    return SectionCard(
      title: '资产收益',
      trailing: SegmentedPills<int>(
        items: const [
          (value: 1, label: '总收益'),
          (value: 0, label: '总资产'),
        ],
        selected: _metric,
        onChanged: (v) => setState(() => _metric = v),
        expand: false,
        itemPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图例 + 当前值（参考图里是「— 总资产」）
          Row(
            children: [
              Container(width: 14, height: 2.4, color: lineColor),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
              const SizedBox(width: 8),
              Text(current,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: lineColor)),
            ],
          ),
          const SizedBox(height: 6),
          AssetValueChart(
            points: points,
            lineColor: lineColor,
            showZeroLine: _metric == 1,
          ),
          _rangePills(context),
        ],
      ),
    );
  }

  // ---------------- 业绩走势（该基金自己的净值走势 + 大盘对照） ----------------

  Widget _perfCard(BuildContext context, AppState state, Asset asset) {
    final theme = Theme.of(context);
    final navs = state.navSamples[asset.code] ?? const <NavPoint>[];
    final pts = navReturnSeries(navs, _range.start, _range.end);
    final refs = pts.isEmpty
        ? const <double?>[]
        : refSeriesOn(
            benchmark: state.benchmark,
            indexNavs: state.benchmarkNavs,
            rangeStart: _range.start,
            dates: [for (final q in pts) q.date],
          );
    final last = pts.isEmpty ? null : pts.last.pct;

    return SectionCard(
      title: '业绩走势',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 14, height: 2.4, color: pnlColor(last ?? 0)),
              const SizedBox(width: 6),
              Text('本基金',
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
              const SizedBox(width: 8),
              Text(last == null ? '--' : fmtPct(last),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: pnlColor(last ?? 0))),
              const Spacer(),
              if (state.benchmark.kind == BenchmarkKind.marketIndex)
                Text('对照 ${state.benchmark.legendName}',
                    style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ],
          ),
          const SizedBox(height: 6),
          if (pts.length < 2)
            SizedBox(
              height: 168,
              child: Center(
                child: Text('这段时间没有这只标的的价格数据',
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ),
            )
          else
            ReturnsLineChart(
              points: pts,
              refs: refs,
              showCallout: true,
              height: 168,
            ),
          _rangePills(context),
        ],
      ),
    );
  }

  // ---------------- 基金档案入口 ----------------

  /// 基金档案入口：档案 / 重仓股 / 分红三块都在那一页（同花顺详情接口，按需拉取）
  ///
  /// 只在基金与场内 ETF/LOF 上出现 —— 同花顺的基金详情接口只认基金，
  /// 股票/黄金点进去只会得到「标的不存在」。
  Widget _fundProfileEntry(BuildContext context, Asset asset) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => FundProfilePage(
              code: asset.code,
              name: asset.name,
              kind: asset.kind,
            ),
          )),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.description_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('基金档案 · 重仓股 · 分红',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                Icon(Icons.chevron_right, size: 20, color: theme.hintColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 打开「编辑」页（简称 / 关联 ETF / 持仓份额 / 单位成本）
  Future<void> _edit(BuildContext context, Asset asset) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AssetEditPage(accountId: widget.accountId, assetId: asset.id!),
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
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
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

  // ---------------- 持仓概览（参考图上没有这八个数字，**保留不删**） ----------------

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
                  child: cell('持有${p.asset.kind.traits.unit}',
                      fmtSharesOf(p.shares,
                          isFund: p.asset.kind.traits.unitIsFund))),
              Expanded(
                  child: cell(
                '成本单价',
                fmtPrice(p.avgCost,
                    digits: p.asset.kind.traits.priceIsLive ? 2 : null),
              )),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: cell(
                  '最新价',
                  p.hasQuote
                      ? fmtPrice(p.price,
                          digits: p.asset.kind.traits.priceIsLive ? 2 : null)
                      : '--',
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
