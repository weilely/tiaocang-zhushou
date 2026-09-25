import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/macro_allocation.dart';

/// 「按利差分位折算股债比」的口径
///
/// 这是用户要的功能里**唯一会被当成"建议"看的数**，所以映射规则必须钉死：
/// 纯机械映射（权益 = 分位），不夹逼、不可有隐藏常数，否则界面上说不清。
void main() {
  group('equityBondSplit：权益 = 分位，债券 = 100 − 分位', () {
    test('分位越高（股票越便宜）权益占比越高', () {
      expect(equityBondSplit(0.43), (43, 57));
      expect(equityBondSplit(0.90), (90, 10));
      expect(equityBondSplit(0.10), (10, 90));
    });

    test('两端都保留：不替用户夹逼成 20%~80% 这种"隐形常数"', () {
      expect(equityBondSplit(0.98), (98, 2));
      expect(equityBondSplit(0.02), (2, 98));
      expect(equityBondSplit(1.0), (100, 0));
      expect(equityBondSplit(0.0), (0, 100));
    });

    test('两者相加恒为 100', () {
      for (var i = 0; i <= 100; i++) {
        final (e, b) = equityBondSplit(i / 100)!;
        expect(e + b, 100);
      }
    });

    test('四位小数分位按四舍五入取整（43.4% → 43 : 57）', () {
      expect(equityBondSplit(0.434), (43, 57));
      expect(equityBondSplit(0.435), (44, 56));
    });

    test('没有分位（样本不足）时返回 null —— 不给没根据的比例', () {
      expect(equityBondSplit(null), isNull);
      expect(equityBondSplitText(null), isNull);
    });

    test('越界的输入被夹在 0~100（上游算错也不至于显示负数）', () {
      expect(equityBondSplit(1.2), (100, 0));
      expect(equityBondSplit(-0.2), (0, 100));
    });

    test('文案固定为「权益 : 债券 = A : B」', () {
      expect(equityBondSplitText(0.43), '权益 : 债券 = 43 : 57');
      expect(equityBondSplitText(0.0), '权益 : 债券 = 0 : 100');
    });
  });

  // 2026-09-24 起：这些是**会被调仓方案使用**的口径，与上面"只展示"的
  // equityBondSplit 区别在「上下限可见可改」+「量化档位」。
  group('equityTargetRatio：分位 → 目标权益占比（方案用）', () {
    test('中间段直读分位：73% → 73%（与关注页那张卡的 73 : 27 一致）', () {
      expect(equityTargetRatio(0.73), closeTo(0.73, 1e-9));
      expect(equityTargetRatio(0.43), closeTo(0.43, 1e-9));
      expect(equityTargetRatio(0.55), closeTo(0.55, 1e-9));
    });

    test('只有两端被上下限截平：5% 只降到 20%、95% 只升到 80%', () {
      expect(equityTargetRatio(0.05), closeTo(0.20, 1e-9));
      expect(equityTargetRatio(0.0), closeTo(0.20, 1e-9));
      expect(equityTargetRatio(0.95), closeTo(0.80, 1e-9));
      expect(equityTargetRatio(1.0), closeTo(0.80, 1e-9));
      // 刚好在边界上不受影响
      expect(equityTargetRatio(0.20), closeTo(0.20, 1e-9));
      expect(equityTargetRatio(0.80), closeTo(0.80, 1e-9));
      expect(equityTargetRatio(0.81), closeTo(0.80, 1e-9));
    });

    test('上下限与档位都是参数：想完全等同展示口径就填 0 / 1', () {
      expect(equityTargetRatio(0.95, floor: 0, cap: 1), closeTo(0.95, 1e-9));
      expect(equityTargetRatio(0.05, floor: 0, cap: 1), closeTo(0.05, 1e-9));
      expect(equityTargetRatio(0.73, floor: 0.5, cap: 0.5), closeTo(0.50, 1e-9));
      // step=0 完全不量化（尾数保留）
      expect(equityTargetRatio(0.7347, step: 0), closeTo(0.7347, 1e-9));
      // 默认 1% 档：尾数被抹掉，数字不跳
      expect(equityTargetRatio(0.7347), closeTo(0.73, 1e-9));
      expect(equityTargetRatio(0.7352), closeTo(0.74, 1e-9));
      // 5% 一档（用户嫌数字天天动时可以调）
      expect(equityTargetRatio(0.73, step: 0.05), closeTo(0.75, 1e-9));
    });

    test('上下限填反了不倒挂（以 floor 为准）', () {
      expect(equityTargetRatio(0.5, floor: 0.8, cap: 0.2), closeTo(0.80, 1e-9));
    });

    test('没有分位（样本不足）→ null：不给建议，保持现状', () {
      expect(equityTargetRatio(null), isNull);
      expect(equityTargetRatio(double.nan), isNull);
    });

    test('越界输入夹在 0~1', () {
      expect(equityTargetRatio(1.5), closeTo(0.80, 1e-9));
      expect(equityTargetRatio(-0.5), closeTo(0.20, 1e-9));
    });
  });

  group('twoLayerTargets：大层（权益比例）× 小层（内部相对比例）', () {
    // 用户真实的权益内部关系 10 : 60 : 30
    final within = {'021362': 0.10, '025497': 0.60, '027858': 0.30};
    final bond = {'007xxx': 1.0};

    test('权益 65% 时按小层等比缩放，另一份给债券腿', () {
      final t = twoLayerTargets(
        equityRelative: within,
        nonEquityRelative: bond,
        equityWeight: 0.65,
      );
      expect(t['021362'], closeTo(0.065, 1e-9));
      expect(t['025497'], closeTo(0.39, 1e-9));
      expect(t['027858'], closeTo(0.195, 1e-9));
      expect(t['007xxx'], closeTo(0.35, 1e-9));
      expect(t.values.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
    });

    test('小层只要求相对关系：3 : 7 与 0.3 : 0.7 等价', () {
      final a = twoLayerTargets(
        equityRelative: {'x': 3, 'y': 7},
        nonEquityRelative: const {},
        equityWeight: 0.5,
      );
      expect(a['x'], closeTo(0.15, 1e-9));
      expect(a['y'], closeTo(0.35, 1e-9));
    });

    test('**没有债券腿时不硬凑**：总和 < 1，由调用方提示缺腿', () {
      final t = twoLayerTargets(
        equityRelative: within,
        nonEquityRelative: const {},
        equityWeight: 0.65,
      );
      expect(t.keys, isNot(contains('007xxx')));
      expect(t.values.fold<double>(0, (a, b) => a + b), closeTo(0.65, 1e-9));
    });

    test('非正的比例被忽略（不产生负数仓位）', () {
      final t = twoLayerTargets(
        equityRelative: {'x': 0, 'y': -1},
        nonEquityRelative: const {},
        equityWeight: 0.5,
      );
      expect(t, isEmpty);
    });

    test('权益 0%（全给债券）或 100% 也不出错', () {
      final all = twoLayerTargets(
        equityRelative: within,
        nonEquityRelative: bond,
        equityWeight: 1.0,
      );
      expect(all['007xxx'], isNull);
      expect(all.values.fold<double>(0, (a, b) => a + b), closeTo(1.0, 1e-9));
      final none = twoLayerTargets(
        equityRelative: within,
        nonEquityRelative: bond,
        equityWeight: 0.0,
      );
      expect(none['021362'], isNull);
      expect(none['007xxx'], closeTo(1.0, 1e-9));
    });
  });

  group('equityRebalanceDue：该不该提示"股债再平衡"', () {
    test('差到 5 个百分点才提示（两个方向都算）', () {
      expect(equityRebalanceDue(current: 1.0, target: 0.94), isTrue);
      expect(equityRebalanceDue(current: 0.60, target: 0.66), isTrue);
      expect(equityRebalanceDue(current: 1.0, target: 0.96), isFalse);
      expect(equityRebalanceDue(current: 0.62, target: 0.65), isFalse);
    });

    test('阈值可调，0 表示只要不一致就提示', () {
      expect(equityRebalanceDue(current: 0.65, target: 0.65, threshold: 0),
          isFalse);
      expect(equityRebalanceDue(current: 0.66, target: 0.65, threshold: 0),
          isTrue);
    });
  });
}
