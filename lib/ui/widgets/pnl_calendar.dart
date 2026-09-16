import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../logic/returns_calendar.dart';
import 'common.dart';

/// 盈亏日历 / 网格：日、月、年三种粒度共用一套渲染
///
/// - 日粒度：7 列，带 `日一二三四五六` 表头，42 格（含前导与尾部空位）
/// - 月粒度：4 列，格内 `1月`…`12月`
/// - 年粒度：4 列，格内 `2026`
///
/// 该期间**没有净值数据**的格子只显示标签、不显示数字——设计稿里 20–30 日
/// 那两行就是这样，比显示 `0.00` 更诚实（0 和「没数据」不是一回事）。
class PnlCalendar extends StatelessWidget {
  final List<PnlCell> cells;
  final ReturnGranularity granularity;

  const PnlCalendar({
    super.key,
    required this.cells,
    required this.granularity,
  });

  static const List<String> weekdayLabels = ['日', '一', '二', '三', '四', '五', '六'];

  bool get _isDay => granularity == ReturnGranularity.day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = _isDay ? 7 : 4;
    final extent = _isDay ? 56.0 : 52.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isDay)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                for (final w in weekdayLabels)
                  Expanded(
                    child: Center(
                      child: Text(w,
                          style: TextStyle(
                              fontSize: 11, color: theme.hintColor)),
                    ),
                  ),
              ],
            ),
          ),
        GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: extent,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: cells.length,
          itemBuilder: (_, i) => _cell(context, cells[i]),
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, PnlCell c) {
    final theme = Theme.of(context);
    // 空位（不属于当月）直接留白
    if (c.label.isEmpty) return const SizedBox.shrink();

    final amount = c.amount;
    // 设计稿的日历是**热力格**：有盈亏的日子带一层很浅的涨/跌色底、且**没有边框**；
    // 没有数据的日子留白，只显示日期号
    return Container(
      decoration: BoxDecoration(
        color:
            amount == null ? null : pnlColor(amount).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            c.label,
            style: TextStyle(
              fontSize: _isDay ? 11 : 12,
              // 有数据的日子用常规文字色，没数据的用灰色以作区分
              color: amount == null
                  ? theme.hintColor
                  : theme.textTheme.bodyMedium?.color,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 1),
          if (amount != null)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                fmtYuanShort(amount),
                maxLines: 1,
                style: TextStyle(
                  fontSize: _isDay ? 11 : 12,
                  fontWeight: FontWeight.w600,
                  color: pnlColor(amount),
                  height: 1.1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `● 盈利  ● 亏损` 图例（红涨绿跌，与 App 其余部分一致）
class PnlLegend extends StatelessWidget {
  const PnlLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget item(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
          ],
        );

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          item(const Color(0xFFD93A3A), '盈利'),
          const SizedBox(width: 28),
          item(const Color(0xFF1A9C5B), '亏损'),
        ],
      ),
    );
  }
}
