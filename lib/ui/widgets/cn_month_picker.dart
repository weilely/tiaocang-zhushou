import 'package:flutter/material.dart';

/// `‹ 2026 年 9 月 ›` 那种「年列 + 月网格」快选面板
///
/// 日期选择器（`cn_date_picker.dart`）与月份选择器共用这一块，
/// 保证两处的年月交互完全一致：左侧年份列可上下滚，右侧 3×4 月份网格。
///
/// 受控组件：`year` / `month` 由父级持有，本组件只负责展示与回调。
class YearMonthPanel extends StatefulWidget {
  /// 当前高亮的年份 / 月份
  final int year;
  final int month;

  final int minYear;
  final int maxYear;

  /// 某个月是否可点（超出可选范围时置灰）
  final bool Function(int year, int month)? monthEnabled;

  /// 某个月是否显示为「已选」
  ///
  /// 默认只比较月份数字；日期选择器需要传入「年份也要对得上」的判定，
  /// 否则在 2025 年视图里会把 2026 年选中的那个月也高亮。
  final bool Function(int year, int month)? monthSelected;

  /// 点了年份
  final void Function(int year)? onYearChanged;

  /// 点了月份（调用方决定是留在面板还是立即确认）
  final void Function(int month)? onMonthSelected;

  const YearMonthPanel({
    super.key,
    required this.year,
    required this.month,
    required this.minYear,
    required this.maxYear,
    this.monthEnabled,
    this.monthSelected,
    this.onYearChanged,
    this.onMonthSelected,
  });

  @override
  State<YearMonthPanel> createState() => _YearMonthPanelState();
}

class _YearMonthPanelState extends State<YearMonthPanel> {
  static const double _rowHeight = 40;

  late final ScrollController _yearCtrl;

  @override
  void initState() {
    super.initState();
    _yearCtrl = ScrollController(initialScrollOffset: _initialOffset());
  }

  @override
  void dispose() {
    _yearCtrl.dispose();
    super.dispose();
  }

  /// 让选中年份大致落在年份列第 3 行，避免一打开就贴在顶部
  double _initialOffset() {
    final raw = (widget.year - widget.minYear) * _rowHeight - _rowHeight * 2;
    return raw < 0 ? 0 : raw;
  }

  bool _enabled(int month) =>
      widget.monthEnabled?.call(widget.year, month) ?? true;

  bool _selected(int month) =>
      widget.monthSelected?.call(widget.year, month) ?? month == widget.month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final years = [
      for (var y = widget.minYear; y <= widget.maxYear; y++) y,
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 92,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: theme.dividerColor, width: 0.6),
              ),
            ),
            child: ListView.builder(
              controller: _yearCtrl,
              itemExtent: _rowHeight,
              itemCount: years.length,
              itemBuilder: (_, i) {
                final y = years[i];
                final on = y == widget.year;
                return InkWell(
                  onTap: () => widget.onYearChanged?.call(y),
                  child: Center(
                    child: Text(
                      '$y年',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        color: on
                            ? theme.colorScheme.primary
                            : theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisExtent: _rowHeight,
            ),
            itemCount: 12,
            itemBuilder: (_, i) => _monthCell(theme, i + 1),
          ),
        ),
      ],
    );
  }

  Widget _monthCell(ThemeData theme, int month) {
    final enabled = _enabled(month);
    final selected = _selected(month);
    final primary = theme.colorScheme.primary;

    return Center(
      child: SizedBox(
        width: 56,
        height: 32,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => widget.onMonthSelected?.call(month) : null,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: selected ? primary.withValues(alpha: 0.14) : null,
              border: selected ? Border.all(color: primary, width: 1) : null,
            ),
            child: Text(
              '$month月',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: !enabled
                    ? theme.disabledColor
                    : selected
                        ? primary
                        : theme.textTheme.bodyMedium?.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 中文月份选择器：选到「哪年哪月」，点了月份立即返回（不额外确认）
///
/// 与 `showCnDatePicker` 共用 [YearMonthPanel]，交互完全一致。
/// 返回 `null` 表示取消。
Future<({int year, int month})?> showCnMonthPicker({
  required BuildContext context,
  required int initialYear,
  required int initialMonth,
  int? minYear,
  int? maxYear,
  String title = '选择月份',
}) {
  final lo = minYear ?? 2000;
  final hi = maxYear ?? DateTime.now().year;
  return showDialog<({int year, int month})>(
    context: context,
    builder: (ctx) => _CnMonthPickerDialog(
      title: title,
      initialYear: initialYear.clamp(lo, hi),
      initialMonth: initialMonth.clamp(1, 12),
      minYear: lo,
      maxYear: hi,
    ),
  );
}

class _CnMonthPickerDialog extends StatefulWidget {
  const _CnMonthPickerDialog({
    required this.title,
    required this.initialYear,
    required this.initialMonth,
    required this.minYear,
    required this.maxYear,
  });

  final String title;
  final int initialYear;
  final int initialMonth;
  final int minYear;
  final int maxYear;

  @override
  State<_CnMonthPickerDialog> createState() => _CnMonthPickerDialogState();
}

class _CnMonthPickerDialogState extends State<_CnMonthPickerDialog> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
    _month = widget.initialMonth;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      title: Row(
        children: [
          Expanded(
            child: Text(widget.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: '关闭',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
      content: SizedBox(
        width: 316,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: Text('$_year年$_month月',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            SizedBox(
              height: 248,
              child: YearMonthPanel(
                year: _year,
                month: _month,
                minYear: widget.minYear,
                maxYear: widget.maxYear,
                onYearChanged: (y) => setState(() => _year = y),
                onMonthSelected: (m) =>
                    Navigator.of(context).pop((year: _year, month: m)),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop((year: _year, month: _month)),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
