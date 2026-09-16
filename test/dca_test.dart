import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/dca_models.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/dca.dart';
import 'package:invest_tracker/logic/holding_import.dart';

void main() {
  // ---------------- 定投日期生成 ----------------

  group('定投应投日期', () {
    test('每月：按日号生成，含跨年', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 11, 1),
        frequency: DcaFrequency.monthly,
        dayOfPeriod: 5,
        until: DateTime(2027, 2, 10),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-11-05', '2026-12-05', '2027-01-05', '2027-02-05']);
    });

    test('每月：日号超过当月天数时钳制到月末', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 1, 1),
        frequency: DcaFrequency.monthly,
        dayOfPeriod: 28,
        until: DateTime(2026, 3, 31),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-01-28', '2026-02-28', '2026-03-28']);
    });

    test('闰年 2 月也能正确钳制', () {
      final ds = dcaPeriods(
        start: DateTime(2028, 2, 1),
        frequency: DcaFrequency.monthly,
        dayOfPeriod: 28,
        until: DateTime(2028, 2, 29),
      );
      expect(ds.map((d) => dayKey(d)).toList(), ['2028-02-28']);
    });

    test('每周：对齐到指定星期几后每 7 天', () {
      // 2026-09-14 是周一
      final ds = dcaPeriods(
        start: DateTime(2026, 9, 14),
        frequency: DcaFrequency.weekly,
        dayOfPeriod: 3, // 周三
        until: DateTime(2026, 10, 5),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-09-16', '2026-09-23', '2026-09-30']);
    });

    test('双周：自首期起每 14 天', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 9, 1),
        frequency: DcaFrequency.biweekly,
        dayOfPeriod: 1,
        until: DateTime(2026, 10, 15),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-09-01', '2026-09-15', '2026-09-29', '2026-10-13']);
    });

    test('首期晚于今天时没有任何应投日', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 12, 1),
        frequency: DcaFrequency.monthly,
        dayOfPeriod: 1,
        until: DateTime(2026, 9, 14),
      );
      expect(ds, isEmpty);
    });
  });

  group('待补记日期', () {
    DcaPlan plan({
      DateTime? start,
      DateTime? lastRun,
      DcaFrequency freq = DcaFrequency.monthly,
      int day = 1,
    }) =>
        DcaPlan(
          accountId: 1,
          assetId: 1,
          amount: 1000,
          frequency: freq,
          dayOfPeriod: day,
          startDate: start ?? DateTime(2026, 8, 1),
          lastRunDate: lastRun,
        );

    test('从未补记 → 从首期起算', () {
      final ds = pendingDcaDates(plan: plan(), today: DateTime(2026, 9, 14));
      expect(ds.map((d) => dayKey(d)).toList(), ['2026-08-01', '2026-09-01']);
    });

    test('已补记到某期 → 只取它之后的', () {
      final ds = pendingDcaDates(
        plan: plan(lastRun: DateTime(2026, 8, 1)),
        today: DateTime(2026, 9, 14),
      );
      expect(ds.map((d) => dayKey(d)).toList(), ['2026-09-01']);
    });

    test('已补齐 → 没有待补记', () {
      final ds = pendingDcaDates(
        plan: plan(lastRun: DateTime(2026, 9, 1)),
        today: DateTime(2026, 9, 14),
      );
      expect(ds, isEmpty);
    });

    test('超过 24 期时只取最近的 24 期', () {
      final ds = pendingDcaDates(
        plan: plan(
          start: DateTime(2024, 1, 1),
          freq: DcaFrequency.monthly,
          day: 1,
        ),
        today: DateTime(2026, 9, 14),
      );
      expect(ds.length, 24);
      // 最后一期应是 2026-09-01
      expect(dayKey(ds.last), '2026-09-01');
      // 第一期应是 2024-10-01（2026-09 往回数 24 期）
      expect(dayKey(ds.first), '2024-10-01');
    });
  });

  group('取价与份额取整', () {
    final prices = {
      '2026-09-11': 4.579, // 周五
      '2026-09-14': 4.600, // 周一
      '2026-09-15': 4.620, // 周二
    };

    test('当天有价用当天', () {
      final ref = resolveDcaPrice(
        due: DateTime(2026, 9, 14),
        today: DateTime(2026, 9, 15),
        priceByDay: prices,
      )!;
      expect(dayKey(ref.date), '2026-09-14');
      expect(ref.price, closeTo(4.600, 1e-9));
    });

    test('非交易日顺延到之后第一个有价日（不越过今天）', () {
      final ref = resolveDcaPrice(
        due: DateTime(2026, 9, 12), // 周六
        today: DateTime(2026, 9, 15),
        priceByDay: prices,
      )!;
      expect(dayKey(ref.date), '2026-09-14');
    });

    test('顺延日还没到今天也没有价 → 返回 null（跳过，不推进断点）', () {
      final ref = resolveDcaPrice(
        due: DateTime(2026, 9, 15), // 今天，净值还没出
        today: DateTime(2026, 9, 15),
        priceByDay: Map.fromEntries(
            prices.entries.where((e) => e.key != '2026-09-15')),
      );
      expect(ref, isNull);
    });

    test('刻意不向前回退取价（不会用定投日之前的净值成交）', () {
      final ref = resolveDcaPrice(
        due: DateTime(2026, 9, 14),
        today: DateTime(2026, 9, 14),
        priceByDay: {'2026-09-11': 4.579}, // 只有更早的价
      );
      expect(ref, isNull);
    });

    test('份额取整：基金 2 位小数，股票/ETF 向下取整', () {
      expect(roundDcaShares(797.4512, AssetKind.fund), closeTo(797.45, 1e-9));
      expect(roundDcaShares(797.9999, AssetKind.fund), closeTo(797.99, 1e-9));
      expect(roundDcaShares(797.99, AssetKind.stock), 797);
      expect(roundDcaShares(797.99, AssetKind.etf), 797);
      expect(roundDcaShares(0, AssetKind.fund), 0);
      expect(roundDcaShares(-1, AssetKind.fund), 0);
    });
  });

  // ---------------- 期初持仓 ----------------

  group('期初持仓校验', () {
    test('份额与成本单价必须为正', () {
      final r = HoldingImportRow(code: '510300', name: '沪深300ETF', shares: 5000, costPrice: 3.14);
      expect(r.validate(), isNull);
      expect(r.valid, isTrue);
      expect(r.amount, closeTo(15700, 1e-9));

      expect(HoldingImportRow(code: '510300', shares: 0, costPrice: 3.14).validate(), '请填份额');
      expect(HoldingImportRow(code: '510300', shares: 100, costPrice: 0).validate(), '请填成本单价');
      expect(HoldingImportRow(shares: 100, costPrice: 1).validate(), '缺少代码');
    });

    test('生成的流水金额 = 份额 × 成本单价，备注为期初持仓', () {
      final r = HoldingImportRow(
          code: '510300', name: '沪深300ETF', kind: AssetKind.etf, shares: 5000, costPrice: 3.14);
      final t = r.toTxn(accountId: 1, assetId: 2, date: DateTime(2026, 9, 1));
      expect(t.type, TxnType.buy);
      expect(t.amount, closeTo(15700, 1e-9));
      expect(t.shares, closeTo(5000, 1e-9));
      expect(t.price, closeTo(3.14, 1e-9));
      expect(t.fee, 0);
      expect(t.note, '期初持仓');
    });

    test('建仓日期不能是未来', () {
      final now = DateTime(2026, 9, 14);
      expect(isValidOpenDate(DateTime(2026, 9, 14), now: now), isTrue);
      expect(isValidOpenDate(DateTime(2026, 9, 13), now: now), isTrue);
      expect(isValidOpenDate(DateTime(2026, 9, 15), now: now), isFalse);
    });
  });


}
