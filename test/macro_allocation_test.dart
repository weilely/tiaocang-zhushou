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

  group('classBasedEquityBondTargets：按大类折算（分母＝持仓市值，现金不进计划）', () {
    // 用户 2026-09-24 的真实持仓（易稳易增）：4 只全是权益，其中 007751 留空
    const total = 320193.26;
    final mv = <String, double>{
      '021362': 31997.76,
      '025497': 187716.09,
      '027858': 100459.58,
      '007751': 19.83,
    };
    final rel = <String, double>{
      '021362': 0.10,
      '025497': 0.60,
      '027858': 0.30,
    };

    test('真实场景：权益池 73%，三只按 10:60:30，留空那只保持现状', () {
      final r = classBasedEquityBondTargets(
        marketValue: mv,
        classes: const {},
        relative: rel,
        equityTarget: 0.73,
      );
      // 没填相对比例 → 保持现状（19.83 元原样留着，不会被"卖光"）
      expect(r.targets['007751']! * total, closeTo(19.83, 0.01));
      final pool = 0.73 * total - 19.83;
      expect(r.targets['021362']! * total, closeTo(pool * 0.10, 0.05));
      expect(r.targets['025497']! * total, closeTo(pool * 0.60, 0.05));
      expect(r.targets['027858']! * total, closeTo(pool * 0.30, 0.05));
      expect(r.equityWeight, closeTo(0.73, 1e-9));
      expect(r.bondWeight, closeTo(0.27, 1e-9));
      // 一只债券都没标 → 明确提示，而不是自己造一个标的
      expect(r.hint, contains('债券'));
    });

    test('标了一只债券腿（市值 5 万）→ 它拿满 27%，权益池相应少一块', () {
      final mv2 = {...mv, '110011': 50000.0};
      final classes = {'110011': AssetClass.bond};
      final r = classBasedEquityBondTargets(
        marketValue: mv2,
        classes: classes,
        relative: {...rel, '110011': 0.9}, // 债券类只有一只，填多少都归一
        equityTarget: 0.73,
      );
      final total2 = total + 50000;
      expect(r.targets['110011']! * total2, closeTo(0.27 * total2, 0.05));
      expect(r.hint, isNull);
      expect(r.targets.values.fold<double>(0, (a, b) => a + b),
          closeTo(1.0, 1e-9));
    });

    test('黄金/其它不参与折算：目标 = 当前占比（保持现状）', () {
      final mv2 = {...mv, '518850': 50000.0};
      final classes = {'518850': AssetClass.gold};
      final r = classBasedEquityBondTargets(
        marketValue: mv2,
        classes: classes,
        relative: rel,
        equityTarget: 0.73,
      );
      final total2 = total + 50000;
      expect(r.targets['518850']! * total2, closeTo(50000, 0.01));
      // 池子是扣掉黄金之后的（320,193.26），所以权益合计 = 0.73 × 池子 / 总额
      expect(r.equityWeight * total2, closeTo(0.73 * total, 0.05));
    });

    test('整类都没填相对比例 → 整池按当前市值比例分（只调总量、内部不动）', () {
      final r = classBasedEquityBondTargets(
        marketValue: mv,
        classes: const {},
        relative: const {},
        equityTarget: 0.50,
      );
      for (final e in mv.entries) {
        expect(r.targets[e.key]! * total,
            closeTo(e.value / total * 0.5 * total, 0.05),
            reason: '${e.key} 的内部占比应保持不变');
      }
    });

    test('权益池比"保持现状"的持仓还小 → 可用部分归零并给提示', () {
      final r = classBasedEquityBondTargets(
        marketValue: mv,
        classes: const {},
        // 只给 021362 填了比例，其余三只（28.8 万）要保持现状
        relative: const {'021362': 1.0},
        equityTarget: 0.20,
      );
      expect(r.targets['021362'], closeTo(0.0, 1e-9));
      expect(r.hint, isNotNull);
      expect(r.targets['025497']! * total, closeTo(187716.09, 0.05));
    });

    test('空持仓 → 空结果 + 提示', () {
      final r = classBasedEquityBondTargets(
        marketValue: const {},
        classes: const {},
        relative: const {},
        equityTarget: 0.73,
      );
      expect(r.targets, isEmpty);
      expect(r.hint, isNotNull);
    });

    test('大类解析：未知/空字符串回 null，由调用方决定默认值', () {
      expect(AssetClassInfo.parse('bond'), AssetClass.bond);
      expect(AssetClassInfo.parse('gold'), AssetClass.gold);
      expect(AssetClassInfo.parse(''), isNull);
      expect(AssetClassInfo.parse(null), isNull);
      expect(AssetClassInfo.parse('xxx'), isNull);
      expect(AssetClass.equity.inEquityBond, isTrue);
      expect(AssetClass.bond.inEquityBond, isTrue);
      expect(AssetClass.gold.inEquityBond, isFalse);
      expect(AssetClass.other.inEquityBond, isFalse);
      expect(AssetClass.bond.label, '债券');
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
