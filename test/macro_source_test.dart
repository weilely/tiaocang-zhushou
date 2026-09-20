import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/macro_source.dart';

/// 股债利差的取数与计算
void main() {
  group('分位计算', () {
    test('样本不足时不给分位（避免刚装上就报个没意义的数）', () {
      expect(percentileOf([1, 2, 3], 2), isNull);
      expect(percentileOf(List.filled(19, 1.0), 1), isNull);
    });

    test('百分位 = 小于等于该值的占比', () {
      final vals = List.generate(100, (i) => i.toDouble()); // 0..99
      expect(percentileOf(vals, 49), closeTo(0.50, 1e-9));
      expect(percentileOf(vals, 98), closeTo(0.99, 1e-9));
      expect(percentileOf(vals, -1), 0);
      expect(percentileOf(vals, 1000), 1);
    });

    test('样本刚好达到下限就给结果', () {
      final vals = List.generate(20, (i) => i.toDouble());
      expect(percentileOf(vals, 10), isNotNull);
    });
  });

  group('MacroPoint', () {
    test('盈利收益率 = 1/PE，利差 = 盈利收益率 − 国债', () {
      const p = MacroPoint(
        date: '2026-09-18',
        hs300Pe: 13.42,
        cn10y: 1.6932,
        erp: 100 / 13.42 - 1.6932,
      );
      expect(p.earningsYield, closeTo(7.4516, 0.001));
      expect(p.erp, closeTo(5.7584, 0.001));
    });

    test('PE 为 0 时盈利收益率给 0，不抛异常', () {
      const p = MacroPoint(date: 'x', hs300Pe: 0, cn10y: 1.7, erp: -1.7);
      expect(p.earningsYield, 0);
    });
  });

  // 直连中证官网 / 东财，网络不通时会红（与 core_test 的联网组同性质）
  group('宏观估值（联网）', () {
    test('中证官网能取到沪深300 PE，且数值合理', () async {
      final pe = await fetchHs300Pe();
      expect(pe, isNotNull, reason: '中证官网 index-perf 取不到 PE');
      expect(pe!.value, greaterThan(5));
      expect(pe.value, lessThan(60));
      expect(pe.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('东财能取到10年国债收益率，且落在合理区间', () async {
      final b = await fetchCn10y();
      expect(b, isNotNull, reason: '东财 171.CN10Y 取不到');
      // f43÷10000 的缩放若写错，这里会明显越界
      expect(b!.value, greaterThan(0.5));
      expect(b.value, lessThan(6));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('合成一次股债利差，各段关系自洽', () async {
      final p = await fetchMacroPoint();
      expect(p, isNotNull);
      expect(p!.hs300Pe, greaterThan(0));
      expect(p.earningsYield, greaterThan(p.cn10y),
          reason: '当前盈利收益率应高于国债收益率（否则利差为负）');
      expect(p.erp, closeTo(p.earningsYield - p.cn10y, 1e-9));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('能回填历史，且点数是「周频 × 三年多」的量级', () async {
      final hist = await fetchMacroBackfill();
      expect(hist, isNotEmpty, reason: '回填拿不到数据，新装用户就没有曲线和分位');
      // 国债历史只有 2023-05 起，PE 是周频 → 大约 170 上下
      expect(hist.length, greaterThan(100));
      expect(hist.length, lessThan(400));
      // 日期升序、无重复、数值合理
      for (var i = 1; i < hist.length; i++) {
        expect(hist[i].date.compareTo(hist[i - 1].date), greaterThan(0));
      }
      for (final p in hist) {
        expect(p.hs300Pe, greaterThan(5));
        expect(p.hs300Pe, lessThan(60));
        expect(p.cn10y, greaterThan(0.5));
        expect(p.cn10y, lessThan(6));
        expect(p.erp, closeTo(100 / p.hs300Pe - p.cn10y, 1e-9));
      }
      // 回填后应该够算分位（阈值 20）
      expect(percentileOf([for (final p in hist) p.erp], hist.last.erp),
          isNotNull);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
