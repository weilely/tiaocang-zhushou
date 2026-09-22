import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/macro_source.dart';

import 'net_helpers.dart';

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

  group('alignMacroSeries：PE 与国债按日期对齐（10 年回填的核心规则）', () {
    test('PE 的每一天取"该日或之前最近"的国债值（周末/节假日顺延）', () {
      final rows = alignMacroSeries(
        pe: {'2026-09-17': 13.5, '2026-09-18': 13.6, '2026-09-19': 13.7},
        // 国债只有 17 号和 19 号有（18 号缺，19 号是周六）
        bond: {'2026-09-17': 1.70, '2026-09-19': 1.72},
      );
      expect(rows.length, 3);
      expect(rows[0].date, '2026-09-17');
      expect(rows[0].cn10y, 1.70);
      expect(rows[1].date, '2026-09-18');
      expect(rows[1].cn10y, 1.70, reason: '18 号没有国债 → 用 17 号的');
      expect(rows[2].cn10y, 1.72);
    });

    test('PE 早于最早一条国债的日期要丢掉（不能拿未来的国债去凑）', () {
      final rows = alignMacroSeries(
        pe: {'2016-01-04': 12.0, '2016-06-16': 13.0},
        bond: {'2016-06-15': 2.95},
      );
      expect(rows.length, 1);
      expect(rows.single.date, '2016-06-16');
      expect(rows.single.cn10y, 2.95);
    });

    test('输出按日期升序，且丢掉非正/缺失的一腿', () {
      final rows = alignMacroSeries(
        pe: {'2026-09-19': 13.7, '2026-09-17': 13.5},
        bond: {'2026-09-17': 1.70, '2026-09-19': 0},
      );
      expect([for (final r in rows) r.date], ['2026-09-17']);
    });

    test('利差 = 1/PE − 国债（自洽）', () {
      final rows = alignMacroSeries(
        pe: {'2026-09-22': 13.5011},
        bond: {'2026-09-22': 1.6791},
      );
      expect(rows.single.erp, closeTo(100 / 13.5011 - 1.6791, 1e-9));
    });

    test('空输入不炸', () {
      expect(alignMacroSeries(pe: const {}, bond: const {'x': 1.0}), isEmpty);
      expect(alignMacroSeries(pe: const {'x': 1.0}, bond: const {}), isEmpty);
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
      if (!await push2Available()) {
        markTestSkipped('push2 网关当前不可用（实测会整站 502），跳过');
        return;
      }
      final b = await fetchCn10y();
      expect(b, isNotNull, reason: '东财 171.CN10Y 取不到');
      // f43÷10000 的缩放若写错，这里会明显越界
      expect(b!.value, greaterThan(0.5));
      expect(b.value, lessThan(6));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('合成一次股债利差，各段关系自洽', () async {
      if (!await push2Available()) {
        markTestSkipped('push2 网关当前不可用，跳过');
        return;
      }
      final p = await fetchMacroPoint();
      expect(p, isNotNull);
      expect(p!.hs300Pe, greaterThan(0));
      expect(p.earningsYield, greaterThan(p.cn10y),
          reason: '当前盈利收益率应高于国债收益率（否则利差为负）');
      expect(p.erp, closeTo(p.earningsYield - p.cn10y, 1e-9));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('能回填历史，且点数是「日频 × 十年」的量级', () async {
      final hist = await fetchMacroBackfill();
      expect(hist, isNotEmpty, reason: '回填拿不到数据，新装用户就没有曲线和分位');
      // 2026-09-22 换源后：国债走东财数据中心（2002 起）、PE 走中证官网日频（2015 起）
      // → 十年日频大约是 2400 上下（去掉任一侧缺失的交易日）
      expect(hist.length, greaterThan(1500), reason: '10 年日频应有 2000+ 条');
      expect(hist.length, lessThan(3200));
      // 最早的一条要能到十年前（否则"10 年口径"就是假的）
      expect(hist.first.date.compareTo('2017-01-01'), lessThan(0),
          reason: '回填必须覆盖到十年前，否则分位口径还是短的');
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
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
