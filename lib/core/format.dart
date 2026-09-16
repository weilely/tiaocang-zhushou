import 'package:intl/intl.dart';

final NumberFormat _money = NumberFormat('#,##0.00');
final NumberFormat _price4 = NumberFormat('#,##0.0000');
final NumberFormat _price3 = NumberFormat('#,##0.000');
final NumberFormat _shares = NumberFormat('#,##0.##');
final NumberFormat _yuanShort = NumberFormat('#,##0');
final DateFormat _date = DateFormat('yyyy-MM-dd');
final DateFormat _dateTime = DateFormat('MM-dd HH:mm');

/// 金额，保留两位
String fmtMoney(double v) {
  if (v.isNaN || v.isInfinite) return '--';
  return _money.format(v);
}

/// 带正负号的金额
String fmtMoneySigned(double v) {
  if (v.isNaN || v.isInfinite) return '--';
  final s = _money.format(v.abs());
  if (v > 0) return '+$s';
  if (v < 0) return '-$s';
  return s;
}

/// 价格：小于 10 显示 4 位，否则 3 位
String fmtPrice(double v) {
  if (v.isNaN || v.isInfinite || v == 0) return '--';
  return v.abs() < 10 ? _price4.format(v) : _price3.format(v);
}

/// 份额
String fmtShares(double v) {
  if (v.isNaN || v.isInfinite) return '--';
  return _shares.format(v);
}

/// 百分比，带正负号
String fmtPct(double v, {int digits = 2}) {
  if (v.isNaN || v.isInfinite) return '--';
  final s = v.abs().toStringAsFixed(digits);
  if (v > 0) return '+$s%';
  if (v < 0) return '-$s%';
  return '$s%';
}

/// 百分比，不带符号（用于占比、目标配置）
String fmtRatioPct(double ratio, {int digits = 1}) {
  if (ratio.isNaN || ratio.isInfinite) return '--';
  return '${(ratio * 100).toStringAsFixed(digits)}%';
}

/// 百分比；null（例如没有行情）显示为 `--`，不要显示成 0%
String fmtPctOrNull(double? v) => v == null ? '--' : fmtPct(v);

String fmtDate(DateTime d) => _date.format(d);

/// `2026年09月11日` —— 日期入口与日期选择器统一用它
///
/// 月/日补零，和总览页「市值更新日期」的写法保持一致，避免同一界面里
/// 一半是 `2026-09-11`、一半是 `2026年09月11日`。
String fmtDateCn(DateTime d) =>
    '${d.year}年${d.month.toString().padLeft(2, '0')}月'
    '${d.day.toString().padLeft(2, '0')}日';

String fmtDateTime(DateTime d) => _dateTime.format(d);

/// 金额紧凑显示（用于图表标签，如 1.2万 / 3.4亿）
String fmtCompact(double v) {
  final a = v.abs();
  if (a >= 1e8) return '${(v / 1e8).toStringAsFixed(2)}亿';
  if (a >= 1e4) return '${(v / 1e4).toStringAsFixed(2)}万';
  return v.toStringAsFixed(0);
}

/// `¥12,345.67`（金额一律 2 位小数 + 千分位）
///
/// [signed] 为真时正数带 `+`、负数带 `-`，用于盈亏与净流入这类有方向的量。
String fmtYuan(double v, {bool signed = false}) {
  if (v.isNaN || v.isInfinite) return '--';
  final s = _money.format(v.abs());
  if (signed) {
    if (v > 0) return '+¥$s';
    if (v < 0) return '-¥$s';
  }
  return '¥$s';
}

/// 日历格里的紧凑金额：`1,844` / `-335`
///
/// 设计稿格内不带正负号、只靠颜色区分盈亏；这里给负值保留 `-`，
/// 免得只靠颜色传达信息（色觉障碍用户读不出方向）。
String fmtYuanShort(double v) {
  if (v.isNaN || v.isInfinite) return '--';
  final s = _yuanShort.format(v.abs());
  return v < 0 ? '-$s' : s;
}

/// `2026-09-11` → `09-11`；图表横轴用
String fmtMonthDay(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// ISO 日期串（`2026-09-11`）→ `09-11`
///
/// 解析不出来就返回空串，调用方据此**不渲染**那一行——宁可少一行，
/// 也不要在一个空占位上显示占位符。
String fmtIsoMonthDay(String? iso) {
  final s = (iso ?? '').trim();
  if (s.length < 10) return '';
  final d = DateTime.tryParse(s.substring(0, 10));
  return d == null ? '' : fmtMonthDay(d);
}

/// 东财净值时间戳（`Data_netWorthTrend[].x`，毫秒）→ `yyyy-MM-dd`
///
/// 那个时间戳代表**净值日 00:00（UTC+8）**：实测 `1789056000000` 对应的就是
/// 2026-09-11 的净值 1.7637。所以必须**固定按 UTC+8** 折算：
/// 用 `DateTime.fromMillisecondsSinceEpoch(ms)`（设备本地时区）去解释的话，
/// 只要手机时区在 UTC+8 以西——出国把时区调成 UTC+0 就会——整条净值序列的
/// 日期都提前一天，日历图的表现就是「周五空着、周日反倒有收益」。
String cnDayFromEpochMillis(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
      .add(const Duration(hours: 8));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
