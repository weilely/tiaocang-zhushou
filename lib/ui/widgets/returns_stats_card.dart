import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/nav_models.dart';
import '../../logic/benchmark.dart';
import '../../logic/range_preset.dart';
import '../../logic/returns_calendar.dart';
import '../../state/app_state.dart';
import 'cash_flow_map.dart';
import 'cn_date_picker.dart';
import 'cn_month_picker.dart';
import 'common.dart';
import 'pnl_calendar.dart';
import 'returns_line_chart.dart';
import 'segmented_pills.dart';

/// 收益统计卡片：日历图 / 趋势图 / 资金流 三个页签
///
/// 放在总览页最底部。页签与粒度的选中态都用「蓝色描边/文字」表达，
/// 不引入新的组件库（项目一贯做法）。
class ReturnsStatsCard extends StatelessWidget {
  const ReturnsStatsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    // 自绘图表单独成层：滚列表时不用跟着别的卡片一起重画
    return RepaintBoundary(
      child: SectionCard(
      title: '收益统计',
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      trailing: _viewTabs(context, st),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (st.missingNavCount > 0) ...[
            _missingNavHint(context, st.missingNavCount),
            const SizedBox(height: 10),
          ],
          switch (st.statsView) {
            StatsView.calendar => const _CalendarView(),
            StatsView.trend => const _TrendView(),
            StatsView.flow => const _FlowView(),
          },
        ],
      ),
      ),
    );
  }

  /// 有标的完全没历史净值时给一句解释
  ///
  /// 典型场景：一只基金早就清仓了，交易记录还在、但它从没被抓过净值 ——
  /// 那时它持有期间的日子在日历上就是空的。不提示的话用户只会觉得「数据没了」。
  Widget _missingNavHint(BuildContext context, int count) {
    final hint = Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 15, color: Color(0xFFB4770A)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '有 $count 只标的还没有历史净值（清仓的也算），它们持有期间的日子显示不出收益。'
              '去「设置 → 数据维护中心 → 重建历史净值」补一次即可。',
              style: TextStyle(fontSize: 11, color: hint, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 页签：设计稿是「浅灰胶囊容器 + 选中项白底蓝字胶囊」，容器贴合内容靠右
  Widget _viewTabs(BuildContext context, AppState st) {
    return SegmentedPills<StatsView>(
      expand: false,
      selected: st.statsView,
      onChanged: st.setStatsView,
      items: const [
        (value: StatsView.calendar, label: '日历图'),
        (value: StatsView.trend, label: '趋势图'),
        (value: StatsView.flow, label: '资金流'),
      ],
    );
  }
}

// ==================== 日历图 ====================

class _CalendarView extends StatelessWidget {
  const _CalendarView();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = st.calendarCursor;
    final cells = st.calendarCells;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _granularitySegments(context, st),
        const SizedBox(height: 10),
        if (st.calendarGranularity != ReturnGranularity.year)
          _periodNav(context, st, c),
        Row(
          children: [
            Text('累计收益',
                style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            const Spacer(),
            // 区间口径：等于当前视图所有格子之和；整屏无数据时显示 --
            PeriodTotalRow(amount: st.calendarPeriodPnl),
          ],
        ),
        const SizedBox(height: 10),
        if (cells.every((x) => x.label.isEmpty))
          _emptyHint(context, '该期间还没有净值数据，去关注页刷新净值')
        else
          PnlCalendar(cells: cells, granularity: st.calendarGranularity),
        const PnlLegend(),
      ],
    );
  }

  Widget _granularitySegments(BuildContext context, AppState st) {
    // 设计稿是「灰容器 + 白底蓝字胶囊」，等分占满整行（此前我用的是蓝描边框）
    return SegmentedPills<ReturnGranularity>(
      selected: st.calendarGranularity,
      onChanged: st.setCalendarGranularity,
      items: [
        for (final g in ReturnGranularity.values) (value: g, label: g.label),
      ],
    );
  }

  Widget _periodNav(
      BuildContext context, AppState st, ({int year, int month}) c) {
    final isDay = st.calendarGranularity == ReturnGranularity.day;
    final label = isDay ? '${c.year}年${c.month}月' : '${c.year}年';
    return Row(
      children: [
        // 设计稿两侧是圆角方形浅灰按钮
        SquareIconButton(
          icon: Icons.chevron_left,
          tooltip: isDay ? '上个月' : '上一年',
          onPressed:
              st.canShiftCalendarBack ? () => st.shiftCalendar(-1) : null,
        ),
        Expanded(
          child: InkWell(
            onTap: () => _pickPeriod(context, st, c),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more,
                      size: 16, color: Theme.of(context).hintColor),
                ],
              ),
            ),
          ),
        ),
        // 设计稿两侧是圆角方形浅灰按钮
        SquareIconButton(
          icon: Icons.chevron_right,
          tooltip: isDay ? '下个月' : '下一年',
          onPressed:
              st.canShiftCalendarForward ? () => st.shiftCalendar(1) : null,
        ),
      ],
    );
  }
  Future<void> _pickPeriod(
      BuildContext context, AppState st, ({int year, int month}) c) async {
    final earliest = st.earliestRecordDay;
    final latest = st.latestRecordDay;
    final picked = await showCnMonthPicker(
      context: context,
      initialYear: c.year,
      initialMonth: c.month,
      minYear: earliest?.year ?? 2000,
      maxYear: latest?.year ?? DateTime.now().year,
    );
    if (picked == null) return;
    st.setCalendarCursor(picked.year, picked.month);
  }
}

// ==================== 趋势图 ====================

class _TrendView extends StatelessWidget {
  const _TrendView();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final range = st.trendRange;
    final points = st.trendPoints;
    final refs = st.trendRefPoints;
    final refPct = st.trendRefPct;
    final stage = st.stagePct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PresetChips(
          presets: trendMainPresets,
          selected: st.trendPreset,
          morePresets: trendMorePresets,
          onSelected: st.setTrendPreset,
          onCustom: () => _pickCustomRange(context, st),
        ),
        const SizedBox(height: 12),
        Text('收益率',
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
        const SizedBox(height: 6),
        _BenchmarkRow(
          benchmark: st.benchmark,
          // 显示的是**本区间折算后**的参考收益率（= 年化 × 天数 ÷ 365），
          // 与下面图例、图上虚线端点同源；年化原值在设置面板里填
          refPct: refPct,
          rangeLabel: st.trendPreset.label,
          onTap: () => _pickBenchmark(context, st),
        ),
        const SizedBox(height: 12),
        if (points.length < 2)
          _emptyHint(context, '该区间还没有净值数据，去关注页刷新净值')
        else ...[
          // 浮动提示现在画在图表内部（设计稿是图上一个深色浮层），
          // 这里不再额外占一行
          ReturnsLineChart(points: points, refs: refs),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 设计稿的图例左项前面有一小段虚线样式样本
                    const DashedLineSample(),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${st.benchmark.legendName} '
                        '${refPct == null ? '无数据' : fmtPct(refPct)}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: refPct == null
                              ? Theme.of(context).hintColor
                              : pnlColor(refPct),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${fmtMonthDay(range.end)} 收益 ${stage == null ? '--' : fmtPct(stage)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color:
                      stage == null ? Theme.of(context).hintColor : pnlColor(stage),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 设计稿里「阶段收益」是**左对齐**紧跟标签，不顶到右边
          Row(
            children: [
              Text('阶段收益',
                  style:
                      TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
              const SizedBox(width: 8),
              Text(
                stage == null ? '--' : fmtPct(stage),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: stage == null ? null : pnlColor(stage),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pickCustomRange(BuildContext context, AppState st) async {
    final now = DateTime.now();
    final earliest = st.earliestRecordDay ?? now.subtract(const Duration(days: 365));
    final start = await showCnDatePicker(
      context: context,
      initialDate: st.trendRange.start,
      firstDate: earliest,
      lastDate: now,
      title: '选择起始日期',
    );
    if (start == null || !context.mounted) return;
    final end = await showCnDatePicker(
      context: context,
      initialDate: st.trendRange.end,
      firstDate: start,
      lastDate: now,
      title: '选择结束日期',
    );
    if (end == null) return;
    st.setTrendCustomRange(start, end);
  }

  Future<void> _pickBenchmark(BuildContext context, AppState st) async {
    final picked = await showModalBottomSheet<Benchmark>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _BenchmarkSheet(
        current: st.benchmark,
        // 面板里补一句"当前区间折算多少"，免得框里的区间值和填的年化值对不上
        rangeLabel: st.trendPreset.label,
        refPct: st.trendRefPct,
      ),
    );
    if (picked == null) return;
    await st.setBenchmark(picked);
  }
}

/// `参考收益率 [0.25] %` —— 外观照设计稿的浅灰圆角框，点开仍可切换自定义年化 / 大盘指数
///
/// 框里显示的是**当前区间折算后的收益率**（自定义年化基准时 = 年化 × 天数 ÷ 365），
/// 不是年化原值 —— 标签写的是"收益率"，就该和图例、虚线端点一个口径。
class _BenchmarkRow extends StatelessWidget {
  final Benchmark benchmark;

  /// 当前区间的参考收益率（%）；null = 取不到（指数没数据等）
  final double? refPct;
  final String rangeLabel;
  final VoidCallback onTap;

  const _BenchmarkRow({
    required this.benchmark,
    required this.refPct,
    required this.rangeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = benchmark.kind == BenchmarkKind.custom;
    final text = custom
        ? (refPct == null ? '--' : _trimPct(refPct!))
        : benchmark.label;

    return Row(
      children: [
        Text('参考收益率',
            style: TextStyle(fontSize: 13, color: theme.hintColor)),
        const SizedBox(width: 10),
        // 设计稿是一个浅灰圆角框：自定义时里面是区间收益率、框外带 %；
        // 指数时里面是「沪深300」。点开仍是切换面板，保留切指数的能力。
        Flexible(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: const BoxConstraints(minWidth: 74),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 16, color: theme.hintColor),
                ],
              ),
            ),
          ),
        ),
        if (custom) ...[
          const SizedBox(width: 8),
          Text('%', style: TextStyle(fontSize: 14, color: theme.hintColor)),
        ],
        const Spacer(),
        if (custom)
          Text(
            '$rangeLabel · 年化 ${_trimPct(benchmark.annualPct)}%',
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
      ],
    );
  }

  /// 0.25 → "0.25"，0.247 → "0.25"，3 位小数以内够用，去掉尾零
  static String _trimPct(double v) {
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }
}

/// 基准切换面板：自定义年化收益率 / 大盘指数（复用 `MarketIndex.presets`）
class _BenchmarkSheet extends StatefulWidget {
  final Benchmark current;

  /// 当前区间名（近1月 / 今年 …），只用于那句折算说明
  final String rangeLabel;

  /// 当前区间的参考收益率（%），null = 取不到
  final double? refPct;

  const _BenchmarkSheet({
    required this.current,
    required this.rangeLabel,
    this.refPct,
  });

  @override
  State<_BenchmarkSheet> createState() => _BenchmarkSheetState();
}

class _BenchmarkSheetState extends State<_BenchmarkSheet> {
  late TextEditingController _pct;

  @override
  void initState() {
    super.initState();
    _pct = TextEditingController(
        text: widget.current.annualPct.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _pct.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = widget.current;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('参考基准',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('趋势图用它做对比基准，可随时切换',
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
            const SizedBox(height: 16),

            // 1) 自定义年化收益率
            _optionTile(
              context,
              selected: cur.kind == BenchmarkKind.custom,
              icon: Icons.percent,
              title: '自定义年化收益率',
              subtitle: '按单利摊到区间天数：年化 × 天数 ÷ 365',
              onTap: () {
                final v = double.tryParse(_pct.text.trim());
                Navigator.of(context).pop(cur.copyWith(
                  kind: BenchmarkKind.custom,
                  annualPct: (v == null || !v.isFinite) ? 3.0 : v,
                ));
              },
            ),
            if (cur.kind == BenchmarkKind.custom) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pct,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: '年化收益率 (%)',
                        isDense: true,
                      ),
                      onSubmitted: (s) {
                        final v = double.tryParse(s.trim());
                        if (v == null || !v.isFinite) return;
                        Navigator.of(context).pop(
                            cur.copyWith(annualPct: v));
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () {
                      final v = double.tryParse(_pct.text.trim());
                      if (v == null || !v.isFinite) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请填一个数字')),
                        );
                        return;
                      }
                      Navigator.of(context)
                          .pop(cur.copyWith(annualPct: v));
                    },
                    child: const Text('用这个'),
                  ),
                ],
              ),
              // 年化是"定义"，框里显示的是"当前区间的折算值"——把两者对上
              if (widget.refPct != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '当前区间（${widget.rangeLabel}）折算为 '
                    '${fmtPct(widget.refPct!)}',
                    style: TextStyle(fontSize: 11, color: theme.hintColor),
                  ),
                ),
            ],

            const Divider(height: 26),

            // 2) 大盘指数
            _optionTile(
              context,
              selected: cur.kind == BenchmarkKind.marketIndex,
              icon: Icons.show_chart,
              title: '大盘指数',
              subtitle: '用指数的真实区间涨跌做基准',
              onTap: null,
            ),
            const SizedBox(height: 4),
            for (final m in MarketIndex.presets)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  cur.kind == BenchmarkKind.marketIndex &&
                          cur.indexCode == m.code
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: cur.kind == BenchmarkKind.marketIndex &&
                          cur.indexCode == m.code
                      ? theme.colorScheme.primary
                      : theme.hintColor,
                ),
                title: Text(m.name, style: const TextStyle(fontSize: 14)),
                subtitle: Text(m.code,
                    style: TextStyle(fontSize: 11, color: theme.hintColor)),
                onTap: () => Navigator.of(context).pop(Benchmark(
                  kind: BenchmarkKind.marketIndex,
                  annualPct: cur.annualPct,
                  indexCode: m.code,
                  indexName: m.name,
                )),
              ),
          ],
        ),
      ),
    );
  }

  Widget _optionTile(
    BuildContext context, {
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: selected ? primary.withValues(alpha: 0.08) : null,
        border: Border.all(
          color: selected ? primary : theme.dividerColor,
          width: selected ? 1.3 : 0.8,
        ),
      ),
      child: ListTile(
        dense: true,
        onTap: onTap,
        leading: Icon(icon,
            size: 20, color: selected ? primary : theme.hintColor),
        title: Text(title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            )),
        subtitle:
            Text(subtitle, style: TextStyle(fontSize: 11, color: theme.hintColor)),
        trailing: selected
            ? Icon(Icons.check_circle, size: 18, color: primary)
            : null,
      ),
    );
  }
}

// ==================== 资金流 ====================

class _FlowView extends StatelessWidget {
  const _FlowView();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final s = st.flowStatement;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PresetChips(
          presets: flowMainPresets,
          selected: st.flowPreset,
          morePresets: flowMorePresets,
          onSelected: st.setFlowPreset,
          onCustom: () => _pickCustomRange(context, st),
        ),
        const SizedBox(height: 4),
        Text(
          '所选区间的各项总量，不是流水明细',
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 12),
        if (s == null)
          _emptyHint(context, '还没有交易或现金记录，先记一笔买入')
        else
          CashFlowMap(s: s),
      ],
    );
  }

  Future<void> _pickCustomRange(BuildContext context, AppState st) async {
    final now = DateTime.now();
    final earliest =
        st.earliestRecordDay ?? now.subtract(const Duration(days: 365));
    final start = await showCnDatePicker(
      context: context,
      initialDate: st.flowRange.start,
      firstDate: earliest,
      lastDate: now,
      title: '选择起始日期',
    );
    if (start == null || !context.mounted) return;
    final end = await showCnDatePicker(
      context: context,
      initialDate: st.flowRange.end,
      firstDate: start,
      lastDate: now,
      title: '选择结束日期',
    );
    if (end == null) return;
    st.setFlowCustomRange(start, end);
  }
}

// ==================== 共用小件 ====================

/// 区间筹码：主筹码一行，`更多` 展开其余预设（含自定义区间）
class PresetChips extends StatelessWidget {
  final List<RangePreset> presets;
  final RangePreset selected;
  final List<RangePreset> morePresets;
  final void Function(RangePreset) onSelected;
  final VoidCallback onCustom;

  const PresetChips({
    super.key,
    required this.presets,
    required this.selected,
    required this.morePresets,
    required this.onSelected,
    required this.onCustom,
  });

  @override
  Widget build(BuildContext context) {
    // 选中的是「更多」里的预设时，主筹码行里没有高亮项
    final inMore = !presets.contains(selected);

    // 设计稿里所有筹码**共用一个浅灰圆角容器**，选中项白底蓝字胶囊、未选中无边框
    return PillGroup(items: [
      for (final p in presets)
        (label: p.label, selected: p == selected, onTap: () => onSelected(p)),
      (
        label: inMore ? selected.label : '更多',
        selected: inMore,
        onTap: () => _showMore(context),
      ),
    ]);
  }

  Future<void> _showMore(BuildContext context) async {
    final picked = await showModalBottomSheet<RangePreset>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in morePresets)
              ListTile(
                dense: true,
                title: Text(p.label),
                trailing: p == selected
                    ? Icon(Icons.check,
                        size: 18, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == RangePreset.custom) {
      onCustom();
      return;
    }
    onSelected(picked);
  }
}

/// 日历图上那行「累计收益」的右侧数值
///
/// 口径是**当前视图区间的合计**（各格之和），不是账户级累计收益，
/// 所以它可能为负 —— 按涨跌上色；整屏没数据时 `amount` 为 `null`，显示 `--`。
class PeriodTotalRow extends StatelessWidget {
  final double? amount;

  const PeriodTotalRow({super.key, required this.amount});

  @override
  Widget build(BuildContext context) {
    final v = amount;
    return Text(
      // 一定带符号：`fmtYuan` 在 signed=false 时会把负数的负号吃掉
      v == null ? '--' : fmtYuan(v, signed: true),
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: v == null ? Theme.of(context).hintColor : pnlColor(v),
      ),
    );
  }
}

Widget _emptyHint(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(Icons.insights_outlined,
              size: 30, color: Theme.of(context).hintColor),
          const SizedBox(height: 8),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                  height: 1.5)),
        ],
      ),
    );
