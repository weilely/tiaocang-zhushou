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

/// 标的的**资产大类**（用户自己在设置页标）。只有 [equity]/[bond] 参与股债平衡；
/// [gold]/[other] 一律**保持现状**（不参与折算）。
enum AssetClass { equity, bond, gold, other }

extension AssetClassInfo on AssetClass {
  String get label => switch (this) {
        AssetClass.equity => '权益',
        AssetClass.bond => '债券',
        AssetClass.gold => '黄金',
        AssetClass.other => '其它',
      };

  /// 是否参与股债平衡的折算
  bool get inEquityBond =>
      this == AssetClass.equity || this == AssetClass.bond;

  /// 从设置里读回来的字符串（未知/为空 → null，由调用方决定默认值）
  static AssetClass? parse(String? raw) {
    for (final c in AssetClass.values) {
      if (c.name == raw) return c;
    }
    return null;
  }
}

/// 折算结果：每个 code 的**目标占比**（相对「持仓市值合计」）+ 要告诉用户的原因。
///
/// [targets] 里出现的每个 code 都是"有目标的"；**不参与折算的类**与**没填相对
/// 比例的标的**都以"当前占比"出现（等价于保持现状，方案里 diff=0、不会乱买卖）。
class ClassTargetResult {
  final Map<String, double> targets;

  /// 权益/债券两类各自的目标占比（相对总持仓市值）
  final double equityWeight;
  final double bondWeight;

  /// 需要提示给用户的原因（null = 一切正常）：缺债券腿、目标比现有持仓还小…
  final String? hint;

  const ClassTargetResult({
    required this.targets,
    required this.equityWeight,
    required this.bondWeight,
    this.hint,
  });

  bool get isEmpty => targets.isEmpty;
}

/// 按「大类」把权益/债券两池折算成**标的级目标占比**（纯函数，可单测）。
///
/// 口径（与界面上的说明必须一致）：
/// 1. 分母是**持仓市值合计**（用户定的：现金不纳入计划）；
/// 2. 黄金/其它（不参与类）与**没填相对比例的标的** → 目标 = 当前占比（保持现状），
///    它们的市值先从池子里扣掉；
/// 3. 剩下的池子按 [equityTarget] 分成权益池与债券池；
/// 4. 每类内部：填了相对比例的按比例分，没填的保持现状；**整类都没填** → 整池
///    按当前市值比例分（等价于只调这一类总量、内部不动）；
/// 5. 缺哪类就**不硬凑**：类里一个标的都没有时那一池不分配，并给出 [hint]
///    （例如"还没有标「债券」的标的"）——绝不自己造一个标的出来。
ClassTargetResult classBasedEquityBondTargets({
  required Map<String, double> marketValue,
  required Map<String, AssetClass> classes,
  required Map<String, double> relative,
  required double equityTarget,
}) {
  final mv = <String, double>{
    for (final e in marketValue.entries)
      if (e.value > 0) e.key: e.value,
  };
  final total = mv.values.fold<double>(0, (a, b) => a + b);
  if (total <= 0) {
    return const ClassTargetResult(
      targets: {},
      equityWeight: 0,
      bondWeight: 0,
      hint: '当前没有持仓市值，算不出比例',
    );
  }

  AssetClass clsOf(String code) => classes[code] ?? AssetClass.equity;

  final out = <String, double>{};
  var passive = 0.0;
  for (final e in mv.entries) {
    if (!clsOf(e.key).inEquityBond) {
      out[e.key] = e.value / total; // 黄金/其它：保持现状
      passive += e.value;
    }
  }

  final x = equityTarget.clamp(0.0, 1.0);
  final pool = total - passive; // 可能为 0（全是黄金/其它）
  final eqPool = pool * x;
  final bondPool = pool * (1 - x);

  String? hint;

  void spread(AssetClass cls, double poolAmount) {
    final codes = [
      for (final e in mv.entries)
        if (clsOf(e.key) == cls) e.key,
    ];
    if (codes.isEmpty) return;

    var relSum = 0.0;
    var pinned = 0.0;
    for (final c in codes) {
      final r = relative[c] ?? 0;
      if (r > 0) {
        relSum += r;
      } else {
        pinned += mv[c]!;
      }
    }

    // 整类都没填相对比例 → 整池按当前市值比例分（只调总量，内部不动）
    if (relSum <= 0) {
      final mvSum = codes.fold<double>(0, (a, c) => a + mv[c]!);
      for (final c in codes) {
        final w = mvSum > 0 ? mv[c]! / mvSum : 1 / codes.length;
        out[c] = w * poolAmount / total;
      }
      return;
    }

    final rest = poolAmount - pinned;
    if (rest < -1e-6) {
      hint ??= '「${cls.label}」的目标比现有持仓还小，这一类先别动';
    }
    final usable = rest > 0 ? rest : 0.0;
    for (final c in codes) {
      final r = relative[c] ?? 0;
      if (r > 0) {
        out[c] = r / relSum * usable / total;
      } else {
        out[c] = mv[c]! / total; // 保持现状
      }
    }
  }

  spread(AssetClass.equity, eqPool);
  spread(AssetClass.bond, bondPool);

  final hasBond = mv.keys.any((c) => clsOf(c) == AssetClass.bond);
  if (!hasBond && bondPool > 1e-9) {
    hint = '还没有标成「债券」的标的，先把一只债券基金在设置里标成债券';
  }

  return ClassTargetResult(
    targets: out,
    equityWeight: eqPool / total,
    bondWeight: bondPool / total,
    hint: hint,
  );
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
