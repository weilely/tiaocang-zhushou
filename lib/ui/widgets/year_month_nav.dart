import 'package:flutter/material.dart';

/// 「年 × 12 + 月」：跨年比较月份就用它，省得写一堆边界判断
int _ymKey(int y, int m) => y * 12 + (m - 1);

/// 年月导航：**外层箭头控年、内侧箭头控月**（用户 2026-09-29 定）
///
/// ```
/// [«] [‹]    2026年9月    [›] [»]
///  年   月                月   年
/// ```
///
/// - 外层是**双箭头、图标大一点**（一次跳一年）；内侧是**单箭头、小一点**（±1 个月）。
/// - [showMonth] = false 时只留年那一对（按月铺满一整屏的视图里，翻月没有意义）。
/// - 可用范围用「年 × 12 + 月」的 key 比大小，越界的那一侧按钮自动置灰。
///
/// 三处共用同一支：日期选择器、月份选择器、收益统计的日历图 —— 都不要再各写一套
/// `‹ 年月 ›` 的导航（用户口径：所有日期控件都用箭头选年月）。
class YearMonthNav extends StatelessWidget {
  const YearMonthNav({
    super.key,
    required this.year,
    required this.month,
    this.showMonth = true,
    this.minYear = 1900,
    this.maxYear = 2999,
    this.minMonth = 1,
    this.maxMonth = 12,
    this.labelSize = 15,
    this.label,
    this.onPrevYear,
    this.onNextYear,
    this.onPrevMonth,
    this.onNextMonth,
  });

  final int year;

  /// 1~12
  final int month;

  final bool showMonth;
  final int minYear;
  final int maxYear;
  final int minMonth;
  final int maxMonth;

  final double labelSize;

  /// 中间那行字；不给就按 [showMonth] 写成 `2026年9月` / `2026年`
  final String? label;

  final VoidCallback? onPrevYear;
  final VoidCallback? onNextYear;
  final VoidCallback? onPrevMonth;
  final VoidCallback? onNextMonth;

  @override
  Widget build(BuildContext context) {
    final now = _ymKey(year, month);
    final lo = _ymKey(minYear, minMonth);
    final hi = _ymKey(maxYear, maxMonth);
    final text = label ?? (showMonth ? '$year年$month月' : '$year年');

    return Row(
      children: [
        _btn(Icons.keyboard_double_arrow_left, 24, '上一年',
            now - 12 >= lo ? onPrevYear : null),
        if (showMonth)
          _btn(Icons.chevron_left, 18, '上个月',
              now - 1 >= lo ? onPrevMonth : null),
        Expanded(
          child: Center(
            child: Text(
              text,
              style: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        if (showMonth)
          _btn(Icons.chevron_right, 18, '下个月',
              now + 1 <= hi ? onNextMonth : null),
        _btn(Icons.keyboard_double_arrow_right, 24, '下一年',
            now + 12 <= hi ? onNextYear : null),
      ],
    );
  }

  Widget _btn(IconData icon, double size, String tip, VoidCallback? onTap) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        onPressed: onTap,
        icon: Icon(icon, size: size),
      );
}
