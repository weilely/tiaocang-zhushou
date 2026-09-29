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

    test('超过 24 期时取**最早**的 24 期（剩下的下一轮继续，一期都不丢）', () {
      final ds = pendingDcaDates(
        plan: plan(
          start: DateTime(2024, 1, 1),
          freq: DcaFrequency.monthly,
          day: 1,
        ),
        today: DateTime(2026, 9, 14),
      );
      expect(ds.length, 24);
      // 从最早那期开始数 24 期（2024-01 ~ 2025-12）
      expect(dayKey(ds.first), '2024-01-01');
      expect(dayKey(ds.last), '2025-12-01');
      // 关键：断点停在 2025-12-01，下一轮的待补记从 2026-01-01 接上（中间不会缺）
      final next = pendingDcaDates(
        plan: plan(
          start: DateTime(2024, 1, 1),
          lastRun: ds.last,
          freq: DcaFrequency.monthly,
          day: 1,
        ),
        today: DateTime(2026, 9, 14),
      );
      expect(dayKey(next.first), '2026-01-01');
    });

    // 用户 2026-09-29：「定投周期增加日定投」
    test('日定投：每天一期，区间内逐日排开', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 9, 1),
        frequency: DcaFrequency.daily,
        dayOfPeriod: 1,
        until: DateTime(2026, 9, 5),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04', '2026-09-05']);
      expect(DcaFrequency.daily.label, '每日');
    });

    test('日定投：计划建得很早时只取最近 hardLimit 期（不能返回几年前那批）', () {
      final ds = dcaPeriods(
        start: DateTime(2020, 1, 1),
        frequency: DcaFrequency.daily,
        dayOfPeriod: 1,
        until: DateTime(2026, 9, 30),
        hardLimit: 100,
      );
      expect(ds.length, 100);
      expect(dayKey(ds.last), '2026-09-30');
      expect(dayKey(ds.first), '2026-06-23', reason: '往回数 99 天');
    });

    test('日定投：待补记按天算，且超过上限时取**最早**那批（不丢中间）', () {
      final p = DcaPlan(
        accountId: 1,
        assetId: 1,
        amount: 100,
        frequency: DcaFrequency.daily,
        dayOfPeriod: 1,
        startDate: DateTime(2026, 9, 1),
      );
      final ds = pendingDcaDates(plan: p, today: DateTime(2026, 9, 5));
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04', '2026-09-05']);

      // 40 期待补、上限 24 → 取最早的 24 期，断点停在 09-24，剩下的下次继续
      final many = pendingDcaDates(
          plan: p, today: DateTime(2026, 10, 10), maxNew: 24);
      expect(many.length, 24);
      expect(dayKey(many.first), '2026-09-01');
      expect(dayKey(many.last), '2026-09-24');
      // 从断点继续：不会漏掉 09-25 起的那批
      final next = pendingDcaDates(
        plan: p.copyWith(lastRunDate: DateTime(2026, 9, 24)),
        today: DateTime(2026, 10, 10),
        maxNew: 24,
      );
      expect(dayKey(next.first), '2026-09-25');
      expect(next.length, 16, reason: '09-25 ~ 10-10 共 16 天');
    });

    test('顺延有上限：超过 15 天才出现的价不能拿来当这一期的成交价', () {
      // 2024-10-01 应投，基金 2024-10-29 才成立（首日净值 1.0）
      final prices = {'2024-10-29': 1.0, '2024-11-01': 0.999};
      expect(
        resolveDcaPrice(
          due: DateTime(2024, 10, 1),
          today: DateTime(2026, 9, 30),
          priceByDay: prices,
        ),
        isNull,
        reason: '28 天后的成立首日价不能冒充 10-01 那期的成交价（实测踩到过）',
      );
      // 15 天以内照旧顺延
      expect(
        dayKey(resolveDcaPrice(
          due: DateTime(2024, 10, 26),
          today: DateTime(2026, 9, 30),
          priceByDay: prices,
        )!
            .date),
        '2024-10-29',
      );
    });

    test('日定投遇周末/休市：顺延到之后第一个有净值的日子', () {      // 2026-09-25(五) 有净值，09-26/27 是周末、09-28(一) 有净值
      final prices = {
        '2026-09-25': 1.5,
        '2026-09-28': 1.6,
      };
      final sat = resolveDcaPrice(
        due: DateTime(2026, 9, 26),
        today: DateTime(2026, 9, 30),
        priceByDay: prices,
      );
      expect(dayKey(sat!.date), '2026-09-28', reason: '周末顺延到周一');
      expect(sat.price, closeTo(1.6, 1e-9), reason: '用扣款日那天的净值');
    });

    test('双周：首期就是期日（不再漂到"首期后 14 天"）', () {
      final ds = dcaPeriods(
        start: DateTime(2026, 9, 3),
        frequency: DcaFrequency.biweekly,
        dayOfPeriod: 1,
        until: DateTime(2026, 10, 3),
      );
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-09-03', '2026-09-17', '2026-10-01']);
    });

    // 用户 2026-09-29：「新增定投添加搜索框选择新的定投目标添加定投计划」
    // —— 没持有的标的也能建计划，所以不能一建就被"标的已清仓"自动掐掉
    test('「从没交易过的标的」不停用计划；清过仓的才停用', () {
      expect(
        shouldDisableForEmptyPosition(everTraded: false, positionEmpty: true),
        isFalse,
        reason: '新搜的标的还没买过 → 计划要能开跑，第一笔买入自己建仓',
      );
      expect(
        shouldDisableForEmptyPosition(everTraded: true, positionEmpty: true),
        isTrue,
        reason: '买过又清仓了 → 老口径，停用',
      );
      expect(
        shouldDisableForEmptyPosition(everTraded: true, positionEmpty: false),
        isFalse,
        reason: '还有持仓，当然不停用',
      );
    });

    test('终止日期之后的期数不再生成（含当天）', () {
      final p = plan(start: DateTime(2026, 1, 1))
          .copyWith(endDate: DateTime(2026, 3, 31));
      final ds = pendingDcaDates(plan: p, today: DateTime(2026, 9, 14));
      expect(ds.map((d) => dayKey(d)).toList(),
          ['2026-01-01', '2026-02-01', '2026-03-01']);
      expect(dayKey(ds.last), '2026-03-01', reason: '4/1 已经过期末了');
    });

    test('终止日期当月那天仍算在内（区间闭合）', () {
      final p = plan(start: DateTime(2026, 1, 1), day: 1)
          .copyWith(endDate: DateTime(2026, 4, 1));
      final ds = pendingDcaDates(plan: p, today: DateTime(2026, 9, 14));
      expect(dayKey(ds.last), '2026-04-01');
    });

    test('没设终止日期 → 一路算到今天（现状不变）', () {
      final ds = pendingDcaDates(plan: plan(), today: DateTime(2026, 9, 14));
      expect(ds.map((d) => dayKey(d)).toList(), ['2026-08-01', '2026-09-01']);
      expect(plan().endDate, isNull);
    });

    test('nextDcaDate：到期后返回 null，未到期返回下一期', () {
      final ended = plan(start: DateTime(2026, 1, 1))
          .copyWith(endDate: DateTime(2026, 3, 31));
      expect(nextDcaDate(ended, DateTime(2026, 9, 14)), isNull);
      expect(ended.endedBy(DateTime(2026, 9, 14)), isTrue);

      final ongoing = plan(start: DateTime(2026, 1, 1))
          .copyWith(endDate: DateTime(2026, 12, 31));
      expect(dayKey(nextDcaDate(ongoing, DateTime(2026, 9, 14))!),
          '2026-10-01');
      expect(ongoing.endedBy(DateTime(2026, 9, 14)), isFalse);
    });

    test('区间文案：有终止写起止，没有只写起', () {
      final p = plan(start: DateTime(2026, 1, 5));
      expect(p.rangeLabel, '2026-01-05 起');
      expect(p.copyWith(endDate: DateTime(2026, 12, 31)).rangeLabel,
          '2026-01-05 ~ 2026-12-31');
    });
  });

  // ---------------- 补记前先看「当天是否已经记过定投」 ----------------
  //
  // 用户 2026-09-25：「补记功能要检查补记当天是否有定投记录，有的话就应该不补」

  group('当天已记过定投就不再补', () {
    Txn t({
      int accountId = 1,
      int assetId = 2,
      String note = '定投',
      DateTime? date,
      TxnType type = TxnType.buy,
    }) =>
        Txn(
          accountId: accountId,
          assetId: assetId,
          type: type,
          date: date ?? DateTime(2026, 9, 14),
          amount: 500,
          shares: 100,
          price: 5,
          note: note,
        );

    test('同一天有「定投」备注的买入 → 记过了', () {
      expect(
        dcaRecordedOn(
          txns: [t()],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isTrue,
      );
    });

    test('手动记的定投（备注「定投 · 9月」）也算', () {
      expect(
        dcaRecordedOn(
          txns: [t(note: '定投 · 9月')],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isTrue,
      );
    });

    test('普通买入（备注里没有「定投」）不算 → 该补还是要补', () {
      expect(
        dcaRecordedOn(
          txns: [t(note: '补仓')],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isFalse,
      );
    });

    test('别的账户 / 别的标的的定投不算', () {
      expect(
        dcaRecordedOn(
          txns: [t(accountId: 9)],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isFalse,
      );
      expect(
        dcaRecordedOn(
          txns: [t(assetId: 99)],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isFalse,
      );
    });

    test('日期不匹配 → 不算（同一个月里的另一天也不行）', () {
      expect(
        dcaRecordedOn(
          txns: [t(date: DateTime(2026, 9, 13))],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isFalse,
      );
    });

    test('应投日与顺延后的成交日，命中任一天都算', () {
      // 应投日周六（9/12）、实际成交在周一（9/14）
      final due = DateTime(2026, 9, 12);
      final dealt = DateTime(2026, 9, 14);
      expect(
        dcaRecordedOn(
          txns: [t(date: dealt)],
          accountId: 1,
          assetId: 2,
          days: [due, dealt],
        ),
        isTrue,
        reason: '顺延时两天都要查，否则会重复补一笔',
      );
      expect(
        dcaRecordedOn(
          txns: [t(date: due)],
          accountId: 1,
          assetId: 2,
          days: [due, dealt],
        ),
        isTrue,
      );
    });

    test('时间带时分秒也能对上（只比到天）', () {
      expect(
        dcaRecordedOn(
          txns: [t(date: DateTime(2026, 9, 14, 15, 30))],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isTrue,
      );
    });

    test('没有流水 → 没记过', () {
      expect(
        dcaRecordedOn(
          txns: const [],
          accountId: 1,
          assetId: 2,
          days: [DateTime(2026, 9, 14)],
        ),
        isFalse,
      );
    });

    test('报告文案里有「当天已记过定投」这一项', () {
      final r = DcaRunReport()..skippedRecorded = 2;
      expect(r.hasAnything, isTrue);
      expect(r.summary, contains('2 期当天已记过定投'));
    });
  });

  // ---------------- 同一标的挂多条计划时的判定 ----------------
  //
  // 用户 2026-09-29：「同一个标的可设置多个定投，补记功能只要期间没有」

  group('多计划：判定落到「哪条计划」上', () {
    DcaPlan plan(int id) => DcaPlan(
          id: id,
          accountId: 1,
          assetId: 2,
          amount: id == 1 ? 1000 : 500,
          frequency: DcaFrequency.monthly,
          dayOfPeriod: 1,
          startDate: DateTime(2026, 1, 1),
        );

    Txn made({int? byPlan, DateTime? date, String note = '定投'}) => Txn(
          accountId: 1,
          assetId: 2,
          type: TxnType.buy,
          date: date ?? DateTime(2026, 9, 1),
          amount: 1000,
          note: note,
          dcaPlanId: byPlan,
        );

    test('计划 1 补过的那一期，不会让计划 2 的同一天期数被跳过', () {
      final a = plan(1);
      final b = plan(2);
      final txns = [made(byPlan: 1)];
      // 同标的有两条计划 → legacyAssetWide 关掉
      expect(
        dcaPeriodRecorded(
            txns: txns,
            plan: a,
            days: [DateTime(2026, 9, 1)],
            legacyAssetWide: false),
        isTrue,
        reason: '这是计划 1 自己补的',
      );
      expect(
        dcaPeriodRecorded(
            txns: txns,
            plan: b,
            days: [DateTime(2026, 9, 1)],
            legacyAssetWide: false),
        isFalse,
        reason: '计划 2 的同一期还没记过，必须照补',
      );
    });

    test('只有一条计划时仍认老口径：手动记的那笔定投算数', () {
      final only = plan(1);
      final manual = made(byPlan: null, note: '定投 · 9月');
      expect(
        dcaPeriodRecorded(
            txns: [manual],
            plan: only,
            days: [DateTime(2026, 9, 1)],
            legacyAssetWide: true),
        isTrue,
      );
      // 多计划场景下同样的行不该算（避免吞掉另一条计划的期数）
      expect(
        dcaPeriodRecorded(
            txns: [manual],
            plan: only,
            days: [DateTime(2026, 9, 1)],
            legacyAssetWide: false),
        isFalse,
      );
    });

    test('顺延后的成交日也认（应投日与成交日命中任一天即可）', () {
      final a = plan(1);
      // 应投 09-05（周六）→ 实际成交 09-07（周一）
      final t = made(byPlan: 1, date: DateTime(2026, 9, 7));
      expect(
        dcaPeriodRecorded(
            txns: [t],
            plan: a,
            days: [DateTime(2026, 9, 5), DateTime(2026, 9, 7)],
            legacyAssetWide: false),
        isTrue,
      );
    });
  });

  // ---------------- 定投的手续费 ----------------
  //
  // 用户 2026-09-25：「定投计划应该考虑费用问题，还有所有交易产生的费用是合并到现金流里的，
  // 假如买入3000元，费用2.5元，那么支出就是302.5元」

  group('每期手续费 = 每期金额 × 申购费率%', () {
    test('他选的费率口径：0.1% 下 300/900/1800 分别是 0.30/0.90/1.80', () {
      expect(dcaFeeFor(amount: 300, feeRatePct: 0.1), closeTo(0.30, 1e-9));
      expect(dcaFeeFor(amount: 900, feeRatePct: 0.1), closeTo(0.90, 1e-9));
      expect(dcaFeeFor(amount: 1800, feeRatePct: 0.1), closeTo(1.80, 1e-9));
    });

    test('钱落到分（四舍五入）', () {
      // 1234.56 × 0.1% = 1.23456 → 1.23
      expect(dcaFeeFor(amount: 1234.56, feeRatePct: 0.1), closeTo(1.23, 1e-9));
      // 5000 × 0.15% = 7.5
      expect(dcaFeeFor(amount: 5000, feeRatePct: 0.15), closeTo(7.5, 1e-9));
    });

    test('费率留空/为 0 → 不计手续费（不是猜一个账户佣金率）', () {
      expect(dcaFeeFor(amount: 3000, feeRatePct: 0), 0);
      expect(dcaFeeFor(amount: 3000, feeRatePct: -1), 0);
    });

    test('金额非法 → 0', () {
      expect(dcaFeeFor(amount: 0, feeRatePct: 0.1), 0);
      expect(dcaFeeFor(amount: -100, feeRatePct: 0.1), 0);
      expect(dcaFeeFor(amount: double.nan, feeRatePct: 0.1), 0);
      expect(dcaFeeFor(amount: double.infinity, feeRatePct: 0.1), 0);
      expect(dcaFeeFor(amount: 1000, feeRatePct: double.nan), 0);
    });

    test('他的例子：买入 3000、费率按 0.0833% → 费约 2.5，支出 3002.50', () {
      final fee = dcaFeeFor(amount: 3000, feeRatePct: 0.0833);
      expect(fee, closeTo(2.50, 0.01));
      expect(3000 + fee, closeTo(3002.50, 0.01));
    });

    test('计划里的费率能原样存读（DB v9 新列）', () {
      final p = DcaPlan(
        accountId: 1,
        assetId: 2,
        amount: 1800,
        frequency: DcaFrequency.weekly,
        dayOfPeriod: 4,
        startDate: DateTime(2026, 9, 18),
        feeRate: 0.1,
      );
      final back = DcaPlan.fromMap(p.toMap());
      expect(back.feeRate, closeTo(0.1, 1e-9));
      expect(p.toMap()['fee_rate'], closeTo(0.1, 1e-9));
      // 老库/老备份的行没有这一列 → 0，不许报错
      final legacy = p.toMap()..remove('fee_rate');
      expect(DcaPlan.fromMap(legacy).feeRate, 0);
    });

    test('报告里会报出补记期数的手续费合计', () {
      final r = DcaRunReport()
        ..created = 3
        ..feeTotal = 0.90;
      expect(r.summary, contains('已按定投计划补记 3 笔'));
      expect(r.summary, contains('含手续费 ¥0.90'));
      // 没手续费就别多写一句
      final r2 = DcaRunReport()..created = 1;
      expect(r2.summary, '已按定投计划补记 1 笔');
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
