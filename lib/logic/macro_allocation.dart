/// 由「股债利差历史分位」折算「权益 : 债券」比值（纯计算，可单测）。
///
/// **口径（必须和界面说明写成一致）**：
///   权益% = 分位 × 100；债券% = 100 − 权益%
/// 即利差分位越高（股票相对债券越便宜）→ 权益占比越高。
///
/// 为什么**不做夹逼**（不设"最低 20%/最高 80%"这类上下限）：
/// 任何夹逼都是我们自己加的一个常数，用户从界面上看不出来 —— 那就成了
/// "编出来一个建议"，而这不是本项目该给的东西（它是估值温度计，不是择时信号）。
/// 纯映射的好处是**可复算**：分位 43% → 权益 43 : 债券 57，谁都能对得上。
library;

/// 返回 `(权益%, 债券%)`，两者相加恒为 100。
///
/// [percentile] 为空（样本不足，界面不给分位）时返回 null —— 宁可什么都不显示，
/// 也不要凭一个没有根据的数给配置比例。
(int equity, int bond)? equityBondSplit(double? percentile) {
  if (percentile == null) return null;
  final e = (percentile * 100).round().clamp(0, 100);
  return (e, 100 - e);
}

/// 说明里那一句「权益 : 债券 = A : B」；没有分位时给 null（由调用方换别的文案）
String? equityBondSplitText(double? percentile) {
  final s = equityBondSplit(percentile);
  if (s == null) return null;
  final (equity, bond) = s;
  return '权益 : 债券 = $equity : $bond';
}
