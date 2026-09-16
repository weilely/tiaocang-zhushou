/// 日历网格的纯数学部分：不依赖 Flutter，方便单测。
///
/// 网格按**周日起始**排布（表头 `日一二三四五六`），与国内主流日历界面一致。
/// 每个月固定返回 6×7 = 42 格，保证对话框高度恒定、不会随月份跳动。
library;

/// 平年各月天数（2 月按 28 天，闰年单独处理）
const List<int> _commonMonthDays = [
  31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
];

/// 一年有多少个格子（6 行 × 7 列）
const int kMonthGridCellCount = 42;

/// 是否闰年：能被 4 整除，但整百年必须能被 400 整除
bool isLeapYear(int year) =>
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

/// 某年某月的天数；月份越界直接报错，避免把错误月份静默算成 31 天
int daysInMonth(int year, int month) {
  if (month < 1 || month > 12) {
    throw ArgumentError.value(month, 'month', '月份必须在 1..12 之间');
  }
  if (month == 2 && isLeapYear(year)) return 29;
  return _commonMonthDays[month - 1];
}

/// 该月 1 号在「周日起始」网格里的偏移（0=周日 … 6=周六）
int firstWeekdayOffset(int year, int month) {
  // DateTime.weekday：1=周一 … 7=周日
  final w = DateTime(year, month, 1).weekday;
  return w % 7;
}

/// 42 个格子；`null` 表示不属于当月的空白格
///
/// 第 `firstWeekdayOffset(y, m)` 格是 1 号，之后连续排到月末，其余为 `null`。
List<int?> monthGrid(int year, int month) {
  final offset = firstWeekdayOffset(year, month);
  final days = daysInMonth(year, month);
  final cells = List<int?>.filled(kMonthGridCellCount, null);
  for (var d = 1; d <= days; d++) {
    cells[offset + d - 1] = d;
  }
  return cells;
}

/// 把「几号」收敛到当月合法范围：2026-02-31 → 28，2024-02-31 → 29
///
/// 用于切换月份时保留「日」：从 1 月 31 日跳到 2 月不会溢出成 3 月。
int clampDay(int year, int month, int day) {
  if (day < 1) return 1;
  final max = daysInMonth(year, month);
  return day > max ? max : day;
}
