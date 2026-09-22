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
}
