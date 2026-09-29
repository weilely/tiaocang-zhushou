import 'package:flutter/material.dart';

import '../../logic/calendar_grid.dart';
import 'year_month_nav.dart';

/// 星期表头（周日起始）
const List<String> _weekdayLabels = ['日', '一', '二', '三', '四', '五', '六'];

/// 日历区固定高度：星期行 26 + 6 行 × 36 = 242，留一点余量
const double _panelHeight = 248;

/// 一个日期格子的边长
const double _dayCellExtent = 36;

/// 中文日期选择器：日历网格 + **箭头换年月**。
///
/// 为什么不用 `showDatePicker`：
/// 本项目没有接入 `flutter_localizations`，Material 的日期选择器会**整屏英文**
/// （`Select date` / `CANCEL` / `OK` / `S M T W T F S`）；
/// 而且换年月要先点标题进年份列表、再逐月翻页，跳几个月很啰嗦。
///
/// 年月怎么翻（用户 2026-09-29 定）：「**外层箭头控年、内侧箭头（比外侧小一点）控月**」
/// —— 见 [YearMonthNav]。以前那种「点标题弹年月快选面板」的做法已经去掉。
///
/// 返回**归一化到年月日**（时分秒为 0）的日期；取消或点外部关闭返回 `null`。
Future<DateTime?> showCnDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String title = '选择日期',
}) {
  final lo = _dateOnly(firstDate ?? DateTime(2000, 1, 1));
  var hi = _dateOnly(lastDate ?? DateTime.now());
  if (hi.isBefore(lo)) hi = lo;

  var init = _dateOnly(initialDate);
  if (init.isBefore(lo)) init = lo;
  if (init.isAfter(hi)) init = hi;

  return showDialog<DateTime>(
    context: context,
    builder: (_) => _CnDatePickerDialog(
      title: title,
      initial: init,
      first: lo,
      last: hi,
    ),
  );
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class _CnDatePickerDialog extends StatefulWidget {
  const _CnDatePickerDialog({
    required this.title,
    required this.initial,
    required this.first,
    required this.last,
  });

  final String title;
  final DateTime initial;
  final DateTime first;
  final DateTime last;

  @override
  State<_CnDatePickerDialog> createState() => _CnDatePickerDialogState();
}

class _CnDatePickerDialogState extends State<_CnDatePickerDialog> {
  /// 当前选中的日期（确定时返回它）
  late DateTime _selected;

  /// 日历正在显示的「年 / 月」，与 [_selected] 解耦：
  /// 翻月只改变视图，不会偷偷改掉用户已经选好的日期。
  late int _cursorYear;
  late int _cursorMonth;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
    _cursorYear = _selected.year;
    _cursorMonth = _selected.month;
  }

  // ---------------- 范围与可用性 ----------------

  /// 日是否可点：整体落在 [first, last] 区间内
  bool _dayEnabled(int day) {
    final d = DateTime(_cursorYear, _cursorMonth, day);
    return !d.isBefore(widget.first) && !d.isAfter(widget.last);
  }

  DateTime get _today => _dateOnly(DateTime.now());

  bool get _todayEnabled =>
      !_today.isBefore(widget.first) && !_today.isAfter(widget.last);

  // ---------------- 交互 ----------------

  /// 只动年（±1）或只动月（±1）—— 箭头由 [YearMonthNav] 的边界判定拦住越界
  void _shiftYear(int delta) => setState(() {
        _cursorYear += delta;
      });

  void _shiftMonth(int delta) {
    var y = _cursorYear;
    var m = _cursorMonth + delta;
    while (m < 1) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    setState(() {
      _cursorYear = y;
      _cursorMonth = m;
    });
  }

  void _pickDay(int day) {
    setState(() => _selected = DateTime(_cursorYear, _cursorMonth, day));
  }

  void _goToday() {
    setState(() {
      _selected = _today;
      _cursorYear = _selected.year;
      _cursorMonth = _selected.month;
    });
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      // 键盘顶起或屏幕很矮时整体可滚，内部各区块用固定高度，不用 Expanded，
      // 因此不会出现溢出条。
      content: SizedBox(
        width: 316,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _navRow(),
              const SizedBox(height: 4),
              SizedBox(
                height: _panelHeight,
                child: _dayPanel(theme),
              ),
              const SizedBox(height: 4),
              _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// 年月导航行：`[«] [‹] 2026年9月 [›] [»]` —— 外层箭头控年、内侧控月
  /// （用户 2026-09-29：「所有日期控件把选择年和月改为箭头选择」）
  Widget _navRow() {
    return YearMonthNav(
      year: _cursorYear,
      month: _cursorMonth,
      minYear: widget.first.year,
      maxYear: widget.last.year,
      minMonth: widget.first.month,
      maxMonth: widget.last.month,
      labelSize: 16,
      onPrevYear: () => _shiftYear(-1),
      onNextYear: () => _shiftYear(1),
      onPrevMonth: () => _shiftMonth(-1),
      onNextMonth: () => _shiftMonth(1),
    );
  }

  // ---------------- 日历面板 ----------------

  Widget _dayPanel(ThemeData theme) {
    final cells = monthGrid(_cursorYear, _cursorMonth);
    return Column(
      children: [
        SizedBox(
          height: 26,
          child: Row(
            children: [
              for (final w in _weekdayLabels)
                Expanded(
                  child: Center(
                    child: Text(w,
                        style: TextStyle(fontSize: 11, color: theme.hintColor)),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: _dayCellExtent,
            ),
            itemCount: kMonthGridCellCount,
            itemBuilder: (_, i) => _dayCell(theme, cells[i]),
          ),
        ),
      ],
    );
  }

  Widget _dayCell(ThemeData theme, int? day) {
    if (day == null) return const SizedBox.shrink();

    final d = DateTime(_cursorYear, _cursorMonth, day);
    final enabled = _dayEnabled(day);
    final selected = _selected.year == d.year &&
        _selected.month == d.month &&
        _selected.day == d.day;
    final isToday = _today.year == d.year &&
        _today.month == d.month &&
        _today.day == d.day;

    final primary = theme.colorScheme.primary;
    final Color? fg = !enabled
        ? theme.disabledColor
        : selected
            ? theme.colorScheme.onPrimary
            : isToday
                ? primary
                : theme.textTheme.bodyMedium?.color;

    return Center(
      child: SizedBox(
        width: _dayCellExtent - 2,
        height: _dayCellExtent - 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? () => _pickDay(day) : null,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? primary : null,
              border: isToday && !selected
                  ? Border.all(color: primary, width: 1)
                  : null,
            ),
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected || isToday ? FontWeight.w700 : FontWeight.w400,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 底部按钮 ----------------

  Widget _footer(ThemeData theme) {
    return Row(
      children: [
        TextButton(
          onPressed: _todayEnabled ? _goToday : null,
          child: const Text('今天'),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
