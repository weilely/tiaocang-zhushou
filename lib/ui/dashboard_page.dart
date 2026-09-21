import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../logic/portfolio.dart';
import '../state/app_state.dart';
import 'cash_manage_page.dart';
import 'txn_edit_page.dart';
import 'widgets/common.dart';
import 'widgets/returns_stats_card.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final summary = state.summary;
    final holdings = state.holdings;

    if (state.txns.isEmpty) {
      return EmptyHint(
        icon: Icons.savings_outlined,
        text: '还没有任何记录\n点击下面按钮，记下第一笔买入',
        action: FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TxnEditPage()),
          ),
          icon: const Icon(Icons.add),
          label: const Text('记一笔'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => state.refreshQuotes(),
      child: ListView(
        // 断开共用的 PrimaryScrollController：IndexedStack 下 5 个页面同时活着，
        // 都挂到同一个 controller 上会互相污染滚动位置（滚动会莫名卡住/跳走）
        primary: false,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _summaryCard(context, state, summary),
          _allocationCard(context, state),
          if (holdings.isEmpty) _noHoldingCard(context),
          // 收益统计放在最底部（日历图 / 趋势图 / 资金流 三个页签）
          const ReturnsStatsCard(),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context, AppState state, PortfolioSummary s) {
    final xirr = s.xirrPct;
    final realizedPct =
        s.invested.abs() > 1e-9 ? s.realized / s.invested * 100 : 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('市值更新日期 ${_marketDateText(s.dayPnlDate)}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 4),
            Text(fmtMoney(state.totalMarketValue),
                style: const TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w700, height: 1.2)),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '持仓市值 ${fmtCompact(s.marketValue)} + 现金 ${fmtCompact(state.cashTotal)}',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
              ),
            ),
            const SizedBox(height: 12),
            // 统一叫「当日收益」：不再按行情日期改名、也不带日期
            _pnlLine(context, s.dayPnlLabel, s.dayPnl, s.dayPnlPct),
            _pnlLine(context, '持仓收益', s.holdingPnl, s.holdingPct),
            _pnlLine(context, '实现收益', s.realized, realizedPct),
            _pnlLine(context, '累计收益', s.cumulativePnl, s.cumulativePct),
            const Divider(height: 20),
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text('现金余额',
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).hintColor)),
                ),
                Text(fmtMoney(state.cashTotal),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const CashManagePage())),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('管理'),
                ),
              ],
            ),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 10),
                title: Text('更多指标',
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor)),
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: StatTile(
                              label: '持仓成本', value: fmtMoney(s.cost))),
                      Expanded(
                        child: StatTile(
                          label: '年化收益率 (XIRR)',
                          value: xirr.isNaN ? '--' : fmtPct(xirr),
                          valueColor: xirr.isNaN ? null : pnlColor(xirr),
                          sub: '按现金流加权',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                          child: StatTile(
                              label: '累计投入', value: fmtCompact(s.invested))),
                      Expanded(
                          child: StatTile(
                              label: '已收回',
                              value: fmtCompact(s.returned),
                              sub: '${s.holdingCount} 个持仓')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `2026-09-11` → `2026年09月11日`；无行情显示 `--`
  static String _marketDateText(String? iso) {
    if (iso == null || iso.length < 10) return '--';
    final d = DateTime.tryParse(iso);
    if (d == null) return '--';
    return '${d.year}年${d.month.toString().padLeft(2, '0')}月'
        '${d.day.toString().padLeft(2, '0')}日';
  }

  /// 一行收益：**标签左对齐、金额左对齐、收益率右对齐**
  Widget _pnlLine(BuildContext context, String label, double amount, double pct) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
          ),
          Text(fmtMoneySigned(amount),
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: pnlColor(amount))),
          const Spacer(),
          SizedBox(
            width: 78,
            child: Text(
              fmtPct(pct),
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: pnlColor(pct)),
            ),
          ),
        ],
      ),
    );
  }

  /// 持仓分布：圆环图 + 图例（**只显示占比、按占比升序、不显示金额**）
  Widget _allocationCard(BuildContext context, AppState state) {
    // 升序：图例与圆环共用同一份顺序，颜色才对得上
    final slices = sortSlicesAscending(state.assetAllocation);
    return SectionCard(
      title: '持仓分布',
      child: LayoutBuilder(
        builder: (context, c) {
          final chart = RepaintBoundary(
            child: DonutChart(
              slices: slices,
              centerLabel: '总市值',
              centerValue: fmtCompact(state.summary.marketValue),
            ),
          );
          final legend = AllocationLegend(slices: slices, showAmount: false);
          if (c.maxWidth < 340) {
            return Column(children: [chart, const SizedBox(height: 16), legend]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              chart,
              const SizedBox(width: 20),
              Expanded(child: legend),
            ],
          );
        },
      ),
    );
  }

  Widget _noHoldingCard(BuildContext context) {
    return SectionCard(
      title: '持仓',
      child: Text(
        '当前没有未卖出的持仓（可能已全部卖出）',
        style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
      ),
    );
  }

  /// 已删除「调仓监控」卡片
  ///
  /// 它按**旧的资产大类目标**算（`cat:` 键），而目标早就改成按具体标的（`asset:` 键）了，
  /// 所以这张卡要么显示"无需调仓"这种噪音、要么拿空目标算出没意义的偏离。
  /// 按标的的调仓方案在「调仓」页，那里才是唯一口径。
  ///
  /// 也删除了「主要持仓」卡片：它列的就是持仓分布图例里的同一批标的。
  /// 想进某个标的的详情页走「持仓」页签。
}
