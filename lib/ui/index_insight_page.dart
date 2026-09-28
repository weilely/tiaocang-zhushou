import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'index_board_page.dart';
import 'index_valuation_page.dart';
import 'widgets/common.dart';
import 'widgets/macro_card.dart';

/// **指数看板**：把「低估榜 / 市场估值 / 查指数」三块收进一个页面，页内用标签切换。
///
/// 用户口径（2026-09-29）：「把股债利差、低估榜、查指数**集成到一个页面**，**入口还在
/// 关注页**，为「**指数看板**」…页面内**以标签的形式**打开各自页面」。
///
/// 所以：关注页只留**一个**入口；三块各自是独立视图（`IndexBoardView` /
/// `MacroDetailView` / `IndexValuationView`），**单独打开时仍是完整页面**
/// （`IndexBoardPage` / `IndexValuationPage`），两处共用同一份实现，不会走偏。
///
/// 标签顺序把**低估榜放第一个**：他是冲「哪些指数低估」来的（当天明确说过），
/// 而股债利差的头条数字在关注页那张卡上已经能看到。
class IndexInsightPage extends StatelessWidget {
  const IndexInsightPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const Text('指数看板'),
            bottom: const TabBar(
              tabs: [
                Tab(text: '低估榜'),
                Tab(text: '市场估值'),
                Tab(text: '查指数'),
              ],
            ),
          ),
          body: const TabBarView(
            children: [
              IndexBoardView(),
              MacroDetailView(),
              IndexValuationView(),
            ],
          ),
        ),
      );
}

/// 「市场估值」标签页：关注页那张卡的**完整版**
/// （大号利差 + 分位 + 曲线 + 按分位折算的股债比 + 口径说明）
class MacroDetailView extends StatefulWidget {
  const MacroDetailView({super.key});

  @override
  State<MacroDetailView> createState() => _MacroDetailViewState();
}

class _MacroDetailViewState extends State<MacroDetailView> {
  bool _busy = false;

  /// 曲线窗口（缩放按钮与曲线共用；手机双指不好按，所以按钮是主要入口）
  final ErpChartController _chart = ErpChartController();

  @override
  void dispose() {
    _chart.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 沪深300 的日线在库里（`nav_history` 的 `sh000300`）—— 没载过就载一次，
    // 载不到就如实说（不硬画一条假的）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final st = context.read<AppState>();
      if (st.benchmarkNavs.isEmpty) unawaited(st.loadIndexNavs());
    });
  }

  Future<void> _refresh() async {
    final st = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await st.refreshMacro(force: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final theme = Theme.of(context);
    final latest = st.macroLatest;
    // 叠加的指数日线（默认基准就是沪深300；他换成别的指数就跟着换，标签一起变）
    final indexSeries = st.benchmarkNavs;
    if (latest == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          SectionCard(
            title: '股债利差',
            trailing: IconButton(
              tooltip: '重新取数',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _busy ? null : _refresh,
            ),
            child: Text(
              st.macroError ?? '还没取到宏观估值数据（沪深300 PE / 10年国债）。',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      );
    }

    final erp = latest.erp;
    final pct = st.macroErpPercentile;
    final days = st.macroHistory.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        SectionCard(
          title: '股债利差',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const SizedBox(
                    width: 13, height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(
                tooltip: '重新取数',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _busy ? null : _refresh,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${erp.toStringAsFixed(2)}%',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: macroErpColor(erp))),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      pct == null
                          ? '样本 $days 天，攒够 20 天后显示分位'
                          : '历史分位 ${(pct * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 11.5, color: theme.hintColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '越大说明股票相对债券越便宜（沪深300盈利收益率 − 10年国债收益率）',
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
              const Divider(height: 18),
              _kv(context, '沪深300 盈利收益率(1/PE)',
                  '${(100 / latest.hs300Pe).toStringAsFixed(2)}%'),
              _kv(context, '沪深300 市盈率 PE',
                  latest.hs300Pe.toStringAsFixed(2)),
              _kv(context, '10 年期国债收益率',
                  '${latest.cn10y.toStringAsFixed(2)}%'),
              // 这一行的值很长（带样本区间），标签单独占一行 —— 否则会被挤成竖排
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本地样本',
                        style: TextStyle(
                            fontSize: 12.5, color: theme.hintColor)),
                    const SizedBox(height: 2),
                    Text(
                        // 点号表达式必须带花括号（见下面那条注释）
                        '$days 天'
                        '${st.macroSampleRange.isEmpty ? '' : '（${st.macroSampleRange}）'}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              _kv(context, '数据日期', latest.date),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: '历史曲线',
          // 缩放按钮放卡头：手机上双指不好按，按钮才是主要入口（手势同样支持）
          trailing: ListenableBuilder(
            listenable: _chart,
            builder: (ctx, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _zoomBtn(Icons.remove, '缩小', _chart.canZoomIn,
                    _chart.zoomOut),
                _zoomBtn(Icons.add, '放大', _chart.canZoomIn, _chart.zoomIn),
                IconButton(
                  tooltip: '复位',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  onPressed: _chart.isFull ? null : _chart.reset,
                ),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图例：两条线各是哪一支、看哪个轴
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _legend(context, theme.colorScheme.primary, '股债利差（左轴 %）'),
                  if (indexSeries.isNotEmpty)
                    _legend(context, kErpIndexLine,
                        '${st.benchmark.indexName} 区间收益（右轴 %）'),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 200,
                child: ErpChart(
                  rows: st.macroHistory,
                  indexSeries: indexSeries,
                  interactive: true,
                  controller: _chart,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                indexSeries.isEmpty
                    ? '${st.benchmark.indexName}的历史还没入库 —— 去「资产收益 → 趋势图」'
                        '把基准选成它就会抓一次，之后这里能叠上它的收益曲线。'
                    : '${st.benchmark.indexName} 这条线从 ${indexSeries.first.date} 起'
                        '（利差从 ${st.macroHistory.isEmpty ? '—' : st.macroHistory.first.date} 起）；'
                        '它的区间收益以当前可见窗口的第一天为基准。'
                        '点卡头 − / + 缩放、复位回全览，也可以双指缩放、单指拖动、双击复位。',
                style: TextStyle(fontSize: 10.5, color: theme.hintColor),
              ),
              // 利差的口径是**固定**用沪深300 的盈利收益率算的；叠加线跟着「基准」设置走。
              // 两者不是同一个指数时（有人把基准换成上证指数），必须把这件事写在脸上，
              // 否则两张图摆一起会得出错结论。
              if (indexSeries.isNotEmpty &&
                  st.benchmark.indexCode != 'sh000300')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '注意：股债利差本身固定按沪深300 的盈利收益率算；'
                    '上面这条叠加线是你选的基准（${st.benchmark.indexName}），两者口径不同。',
                    style: TextStyle(
                        fontSize: 10.5, color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: '怎么算的、怎么用',
          child: Text(
            macroExplainText(st),
            style: TextStyle(
                fontSize: 11.5, color: theme.hintColor, height: 1.6),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '数据来源：10 年国债走东财数据中心「中美国债收益率」；沪深300 PE 走中证指数官网'
          '（日频）。本地历史是安装时自动回填 + 每天累积的。\n'
          '它是市场级的估值温度计，不是择时信号，也不构成投资建议。',
          style: TextStyle(fontSize: 10.5, color: theme.hintColor),
        ),
      ],
    );
  }

  /// 卡头的小按钮（缩放/复位）
  Widget _zoomBtn(
          IconData icon, String tip, bool enabled, VoidCallback onTap) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        icon: Icon(icon, size: 18),
        onPressed: enabled ? onTap : null,
      );

  /// 图例：一小段线 + 说明（两条线颜色不同，别让人猜）
  Widget _legend(BuildContext context, Color color, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 14, height: 2.4, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 10.5, color: Theme.of(context).hintColor)),
        ],
      );

  Widget _kv(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5, color: Theme.of(context).hintColor)),
            ),
            Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
