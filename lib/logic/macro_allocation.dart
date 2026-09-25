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

// ---------------------------------------------------------------------------
// 下面这几个是**会被调仓方案使用**的口径（2026-09-24 用户提出：「根据股债利差
// 把股债平衡纳入自动调仓计划」）。它们与上面只管展示的 [equityBondSplit] 有
// 两个关键区别，别把两者搞混：
//   ①上下限 [floor]/[cap] **由用户在界面上设定、并在界面上显示** —— 不是藏在
//     代码里的夹逼常数（那才违背上面那条原则）。分位 0% 就清空权益、100% 就
//     满仓，多数人并不想那样，所以给一个**看得见、改得动**的边界。
//   ②量化到 [step] 档位 —— 分位是日频的，不量化就会天天冒出一条"调仓建议"。
// ---------------------------------------------------------------------------

/// 目标权益占比（0~1）：把利差分位映射成"会被方案使用的"目标仓位。
///
/// **中间段直读**：分位 73% → 权益 73%，与关注页那张「市场估值」卡上的
/// 「权益 : 债券 = 73 : 27」**完全一致**（两处数字打架是最容易让人不信的）。
/// 只有两端被 [floor] / [cap] 截平（默认 20% / 80%）：
/// 分位 5% 也只降到 20%、分位 95% 也只升到 80% —— 分位 0 就清空权益、
/// 100 就满仓，多数人并不想那样。
///
/// **[floor]/[cap] 要显示在界面上、并且可以改**：它一旦藏起来就变成"我们替
/// 用户编的常数"（见本文件开头那条原则）。想完全等同展示口径就填 0 / 1。
///
/// [step]：量化档位（默认 1%）。分位本身就是整数百分比，这一步只是防止
/// 0.7347 这种尾数跳来跳去；想更稳可以调到 0.05（5% 一档）。
/// [percentile] 为 null/NaN（样本不足，界面本来就不给分位）→ 返回 null：
/// **不给建议、保持现状**，而不是拿一个没根据的数去动用户的仓位。
double? equityTargetRatio(
  double? percentile, {
  double floor = 0.20,
  double cap = 0.80,
  double step = 0.01,
}) {
  if (percentile == null || percentile.isNaN) return null;
  final lo = floor.clamp(0.0, 1.0);
  final hi = cap.clamp(lo, 1.0); // 上下限填反了以 floor 为准，不要倒挂
  final p = percentile.clamp(0.0, 1.0);
  final raw = step <= 0 ? p : (p / step).round() * step;
  // 浮点噪声（0.7300000000000001）不要带出去；先量化再截断到上下限
  return double.parse(raw.toStringAsFixed(4)).clamp(lo, hi);
}

/// 两层目标折算成**标的级**目标占比（同一 code 只出现一次，总和 ≤ 1）。
///
/// 大层由股债利差分位给（[equityWeight]，通常来自 [equityTargetRatio]），
/// 小层是用户原来填的相对比例（如 10 : 60 : 30 = 权益内部谁多谁少）；
/// 两者相乘才是标的级目标 —— 这样分位天天变，也只要重算大层，用户填的小层
/// 关系一个字都不用改（现有的调仓引擎照旧吃标的级目标）。
///
/// **缺一类时不要硬凑**：某一类为空（例如他还没买债券基金）时，那一份权重就
/// 不分配、结果总和会小于 1；调用方据此提示「缺少债券腿」，而不是自己造一个
/// 标的出来（"失败/缺失"不能当成"有数据"）。
Map<String, double> twoLayerTargets({
  required Map<String, double> equityRelative,
  required Map<String, double> nonEquityRelative,
  required double equityWeight,
}) {
  final e = equityWeight.clamp(0.0, 1.0);
  final out = <String, double>{};

  void spread(Map<String, double> rel, double weight) {
    if (weight <= 0) return;
    var sum = 0.0;
    for (final v in rel.values) {
      if (v > 0) sum += v;
    }
    if (sum <= 0) return;
    rel.forEach((code, v) {
      if (v <= 0) return;
      out[code] = (out[code] ?? 0) + v / sum * weight;
    });
  }

  spread(equityRelative, e);
  spread(nonEquityRelative, 1 - e);
  return out;
}

/// 该不该在方案里提示「股债再平衡」：目标权益占比与**当前实际**权益占比
/// 相差**超过** [threshold]（默认 5 个百分点）才提示 —— 否则天天在边界上抖。
/// [threshold] 给 0 表示不设缓冲（只要不一样就提示）。
bool equityRebalanceDue({
  required double current,
  required double target,
  double threshold = 0.05,
}) =>
    (target - current).abs() > threshold;
