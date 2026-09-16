import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/benchmark.dart';

void main() {
  NavPoint close(String date, double v) =>
      NavPoint(code: 'sh000300', date: date, nav: v, accNav: v);

  final hs300 = [
    close('2022-08-02', 4107.0),
    close('2026-09-01', 4400.0),
    close('2026-09-08', 4520.0),
    close('2026-09-14', 4480.0),
  ];

  group('自定义年化收益率（单利摊到天数）', () {
    const b = Benchmark(annualPct: 3.0);

    test('365 天正好等于年化；30 天按比例', () {
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 1, 1),
          day: DateTime(2027, 1, 1),
        ),
        closeTo(3.0, 1e-9),
      );
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 10, 1),
        ),
        closeTo(3.0 * 30 / 365, 1e-9),
      );
    });

    test('区间起点当天为 0；早于起点返回 null', () {
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 9, 1),
        ),
        0,
      );
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 8, 31),
        ),
        isNull,
      );
    });

    test('0 与负数都允许', () {
      const zero = Benchmark(annualPct: 0);
      expect(
        refPctOn(
          benchmark: zero,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 9, 30),
        ),
        0,
      );
      const neg = Benchmark(annualPct: -6.0);
      final v = refPctOn(
        benchmark: neg,
        indexNavs: const [],
        rangeStart: DateTime(2026, 9, 1),
        day: DateTime(2026, 10, 1),
      );
      expect(v, closeTo(-6.0 * 30 / 365, 1e-9));
      expect(v! < 0, isTrue);
    });

    test('跨闰年按实际天数', () {
      // 2024-02-01 → 2024-03-01 是 29 天（2024 是闰年）
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2024, 2, 1),
          day: DateTime(2024, 3, 1),
        ),
        closeTo(3.0 * 29 / 365, 1e-9),
      );
    });

    test('从不需要指数数据（传空也不影响）', () {
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 9, 11),
        ),
        isNotNull,
      );
    });
  });

  group('大盘指数基准', () {
    const b = Benchmark(
      kind: BenchmarkKind.marketIndex,
      indexCode: 'sh000300',
      indexName: '沪深300',
    );

    test('区间收益 = close(末)/close(起) − 1', () {
      expect(
        refPctOfRange(
          benchmark: b,
          indexNavs: hs300,
          rangeStart: DateTime(2026, 9, 1),
          rangeEnd: DateTime(2026, 9, 14),
        ),
        closeTo((4480.0 / 4400.0 - 1) * 100, 1e-9),
      );
    });

    test('非交易日按前向填充取最近收市价', () {
      // 09-12/09-13 是周末，取 09-08 的 4520
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: hs300,
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 9, 13),
        ),
        closeTo((4520.0 / 4400.0 - 1) * 100, 1e-9),
      );
    });

    test('指数没有数据时返回 null，不编造基准值', () {
      expect(
        refPctOn(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          day: DateTime(2026, 9, 14),
        ),
        isNull,
      );
      expect(
        refPctOfRange(
          benchmark: b,
          indexNavs: const [],
          rangeStart: DateTime(2026, 9, 1),
          rangeEnd: DateTime(2026, 9, 14),
        ),
        isNull,
      );
    });

    test('区间早于指数首个数据日时对齐到指数首日', () {
      // 指数只有 2022-08-02 起的数据，区间从 2020-01-01 开始
      final aligned = alignedStart(DateTime(2020, 1, 1), hs300);
      expect(aligned, DateTime(2022, 8, 2));

      // 区间起点晚于指数首日时，就用区间起点
      expect(alignedStart(DateTime(2026, 9, 1), hs300), DateTime(2026, 9, 1));
    });

    test('对齐后两条曲线从同一天起算', () {
      final dates = [
        DateTime(2026, 8, 20), // 早于对齐起点之前没有意义，这里起点就是区间起点
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 8),
      ];
      final refs = refSeriesOn(
        benchmark: b,
        indexNavs: hs300,
        rangeStart: DateTime(2026, 9, 1),
        dates: dates,
      );
      expect(refs.length, 3);
      // 2026-09-01 是区间起点也是指数有数据的一天 → 基准 0
      expect(refs[1], closeTo(0, 1e-9));
      expect(refs[2], closeTo((4520.0 / 4400.0 - 1) * 100, 1e-9));
    });

    test('区间比指数历史更早时，早于基准首日的点返回 null 而不是 0', () {
      final refs = refSeriesOn(
        benchmark: b,
        indexNavs: hs300,
        rangeStart: DateTime(2020, 1, 1),
        dates: [
          DateTime(2020, 1, 2),
          DateTime(2022, 8, 2),
          DateTime(2026, 9, 1),
        ],
      );
      expect(refs[0], isNull, reason: '基准那时还没数据，不能当 0');
      expect(refs[1], closeTo(0, 1e-9), reason: '对齐首日基准为 0');
      expect(refs[2], isNotNull);
    });

    test('图例名用指数名', () {
      expect(b.legendName, '沪深300');
      expect(const Benchmark().legendName, '参考收益');
      expect(b.label, '沪深300');
    });
  });

  group('设置的读写', () {
    test('默认值', () {
      final b = Benchmark.fromSettings(null, null, null, null);
      expect(b.kind, BenchmarkKind.custom);
      expect(b.annualPct, 3.0);
      expect(b.indexCode, 'sh000300');
      expect(b.indexName, '沪深300');
    });

    test('往返回归（序列化 → 反序列化）', () {
      const orig = Benchmark(
        kind: BenchmarkKind.marketIndex,
        annualPct: 4.5,
        indexCode: 'sz399006',
        indexName: '创业板指',
      );
      final s = orig.toSettings();
      final back = Benchmark.fromSettings(
        s['benchmarkKind'],
        s['benchmarkAnnualPct'],
        s['benchmarkIndexCode'],
        s['benchmarkIndexName'],
      );
      expect(back.kind, orig.kind);
      expect(back.annualPct, orig.annualPct);
      expect(back.indexCode, orig.indexCode);
      expect(back.indexName, orig.indexName);
    });

    test('非法百分比回落到默认，不会把 NaN 存进去', () {
      expect(Benchmark.fromSettings('custom', 'abc', null, null).annualPct, 3.0);
      expect(Benchmark.fromSettings('custom', '', null, null).annualPct, 3.0);
      expect(
          Benchmark.fromSettings('custom', 'double.nan', null, null).annualPct, 3.0);
      expect(Benchmark.fromSettings('custom', '-2', null, null).annualPct, -2.0);
    });

    test('未知 kind 当成自定义，不会崩', () {
      expect(Benchmark.fromSettings('nonsense', '5', null, null).kind,
          BenchmarkKind.custom);
    });
  });
}
