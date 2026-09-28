import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/fund_detail.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/redeem_fee.dart';

/// 场外赎回费：按持有天数的档位表 + 先进先出（用户 2026-09-28 发来参考图）
void main() {
  Txn buy(String d, double shares, {int id = 0, String note = ''}) => Txn(
        id: id,
        accountId: 1,
        assetId: 1,
        type: TxnType.buy,
        date: DateTime.parse(d),
        amount: shares,
        shares: shares,
        price: 1,
        note: note,
      );

  Txn sell(String d, double shares, {int id = 0}) => Txn(
        id: id,
        accountId: 1,
        assetId: 1,
        type: TxnType.sell,
        date: DateTime.parse(d),
        amount: shares,
        shares: shares,
        price: 1,
      );

  final asOf = DateTime.parse('2026-09-28');

  group('FIFO 批次', () {
    test('多笔买入按日期升序成批次；卖出先扣最早的', () {
      final lots = fifoLots([
        buy('2026-01-10', 100, id: 1),
        buy('2026-06-10', 200, id: 2),
        sell('2026-09-01', 150, id: 3),
      ], asOf: asOf);
      // 最早那批 100 被卖光 → 从结果里剔除；第二批只剩 150
      expect(lots.length, 1);
      expect(lots.single.date, DateTime.parse('2026-06-10'));
      expect(lots.single.shares, 150);
    });

    test('成本调整（0 份额）不进批次', () {
      final lots = fifoLots([
        buy('2026-01-10', 100, id: 1),
        Txn(
          id: 2,
          accountId: 1,
          assetId: 1,
          type: TxnType.buy,
          date: DateTime.parse('2026-05-01'),
          amount: 50,
          shares: 0,
          note: Txn.costAdjustNote,
        ),
      ], asOf: asOf);
      expect(lots.length, 1);
      expect(lots.single.shares, 100);
    });

    test('当天买入的那批不算可卖（T+1，与 sellableShares 同口径）', () {
      final lots = fifoLots([
        buy('2026-09-28', 100, id: 1),
      ], asOf: asOf);
      expect(lots, isEmpty);
      // 关掉这个口径就看得见（供分布弹框里单独提示"今天买的 N 份 T+1 后才能卖"）
      final all = fifoLots([
        buy('2026-09-28', 100, id: 1),
      ], asOf: asOf, skipToday: false);
      expect(all.single.shares, 100);
    });
  });

  group('档位归属（左闭右开）', () {
    test('0~7 / 7~30 / 30~365 / 365~730 / ≥730', () {
      final t = kDefaultRedeemTiers;
      expect(tierForDays(0, t)!.ratePct, 1.5);
      expect(tierForDays(6, t)!.ratePct, 1.5);
      expect(tierForDays(7, t)!.ratePct, 0.75, reason: '第 7 天进第二档');
      expect(tierForDays(29, t)!.ratePct, 0.75);
      expect(tierForDays(30, t)!.ratePct, 0.5);
      expect(tierForDays(364, t)!.ratePct, 0.5);
      expect(tierForDays(365, t)!.ratePct, 0.25);
      expect(tierForDays(729, t)!.ratePct, 0.25);
      expect(tierForDays(730, t)!.ratePct, 0);
      expect(tierForDays(5000, t)!.ratePct, 0);
    });

    test('分布表的文案与参考图一致', () {
      expect(kDefaultRedeemTiers.map((t) => t.label).toList(), [
        '0~7 天(不含)',
        '7~30 天(不含)',
        '30~365 天(不含)',
        '365~730 天(不含)',
        '≥730 天',
      ]);
    });
  });

  group('卖出费率分布', () {
    test('按批次落档：老批次进 30~365，新批次进 7~30', () {
      final lots = fifoLots([
        buy('2026-01-10', 1000, id: 1), // 261 天 → 30~365 档
        buy('2026-09-10', 300, id: 2), // 18 天 → 7~30 档
      ], asOf: asOf);
      final rows = tierBreakdown(
          lots: lots, asOf: asOf, tiers: kDefaultRedeemTiers);
      expect(rows[0].shares, 0); // 0~7
      expect(rows[1].shares, 300); // 7~30
      expect(rows[2].shares, 1000); // 30~365
      expect(rows[3].shares, 0);
      expect(rows[4].shares, 0);
    });
  });

  group('卖出费用估算（FIFO 逐批）', () {
    test('全部落在同一档：300 份 × 1.2 元 × 0.5% = 1.80', () {
      final lots = fifoLots([buy('2026-01-10', 1000, id: 1)], asOf: asOf);
      final r = estimateRedeemFee(
        lots: lots,
        sellShares: 300,
        date: asOf,
        nav: 1.2,
        tiers: kDefaultRedeemTiers,
      );
      expect(r.fee, closeTo(1.80, 1e-9));
      expect(r.hits.single.days, 261);
      expect(r.hits.single.tier!.ratePct, 0.5);
    });

    test('跨档：先卖老批次（0.5%）再卖新批次（1.5%）', () {
      final lots = fifoLots([
        buy('2026-01-10', 100, id: 1), // 261 天 → 0.5%
        buy('2026-09-26', 100, id: 2), // 2 天 → 1.5%
      ], asOf: asOf);
      final r = estimateRedeemFee(
        lots: lots,
        sellShares: 150,
        date: asOf,
        nav: 2,
        tiers: kDefaultRedeemTiers,
      );
      // 100×2×0.5% = 1.00 ＋ 50×2×1.5% = 1.50 → 2.50
      expect(r.fee, closeTo(2.50, 1e-9));
      expect(r.hits.length, 2);
      expect(r.hits[0].tier!.ratePct, 0.5);
      expect(r.hits[1].tier!.ratePct, 1.5);
    });

    test('≥730 天 0 费率：卖老批次不花钱', () {
      final lots = fifoLots([buy('2024-01-10', 500, id: 1)], asOf: asOf);
      final r = estimateRedeemFee(
        lots: lots,
        sellShares: 500,
        date: asOf,
        nav: 1.5,
        tiers: kDefaultRedeemTiers,
      );
      expect(r.fee, 0);
    });

    test('可卖份额不足时按实际命中的部分算，不报错', () {
      final lots = fifoLots([buy('2026-01-10', 100, id: 1)], asOf: asOf);
      final r = estimateRedeemFee(
        lots: lots,
        sellShares: 300,
        date: asOf,
        nav: 1,
        tiers: kDefaultRedeemTiers,
      );
      expect(r.hits.single.shares, 100);
      expect(r.fee, closeTo(0.5, 1e-9));
    });

    test('净值/份额非法 → 0 费用且没有命中批', () {
      final lots = fifoLots([buy('2026-01-10', 100, id: 1)], asOf: asOf);
      expect(
          estimateRedeemFee(
            lots: lots,
            sellShares: 0,
            date: asOf,
            nav: 1,
            tiers: kDefaultRedeemTiers,
          ).fee,
          0);
      expect(
          estimateRedeemFee(
            lots: lots,
            sellShares: 10,
            date: asOf,
            nav: 0,
            tiers: kDefaultRedeemTiers,
          ).hits,
          isEmpty);
    });
  });

  // 用户 2026-09-28：「得参考基金档案赎回费率」——真 Key 实测两种形态：
  // 004814 是 5 档（7天以下/7天(包含)-30天/30天(包含)-365天/365天(包含)-730天/730天以上(包含)），
  // 025497、021362、027858 只有 2 档（7天以下 / 7天以上(包含)）
  group('从基金档案解析赎回档位', () {
    FundRate rate(String cond, String std) => FundRate(
          type: 'redemption',
          chargeMode: 'default',
          condition: cond,
          standardRate: std,
        );

    test('5 档型（004814 实测文案）逐条对得上', () {
      final tiers = parseRedeemTiers([
        rate('7天以下', '1.50%'),
        rate('7天(包含)-30天', '0.75%'),
        rate('30天(包含)-365天', '0.50%'),
        rate('365天(包含)-730天', '0.25%'),
        rate('730天以上(包含)', '0.00%'),
      ]);
      expect(tiers.length, 5);
      expect(tiers[0].minDays, 0);
      expect(tiers[0].maxDays, 7);
      expect(tiers[0].ratePct, 1.5);
      expect(tiers[1].minDays, 7);
      expect(tiers[1].maxDays, 30);
      expect(tiers[2].minDays, 30);
      expect(tiers[2].maxDays, 365);
      expect(tiers[3].minDays, 365);
      expect(tiers[3].maxDays, 730);
      expect(tiers[4].minDays, 730);
      expect(tiers[4].maxDays, isNull);
      expect(tiers[4].ratePct, 0);
      // 逐天归属
      expect(tierForDays(6, tiers)!.ratePct, 1.5);
      expect(tierForDays(7, tiers)!.ratePct, 0.75);
      expect(tierForDays(400, tiers)!.ratePct, 0.25);
      expect(tierForDays(9999, tiers)!.ratePct, 0);
    });

    test('2 档型（025497/021362/027858 实测文案）', () {
      final tiers = parseRedeemTiers([
        rate('7天以下', '1.50%'),
        rate('7天以上(包含)', '0.00%'),
      ]);
      expect(tiers.length, 2);
      expect(tiers[0].maxDays, 7);
      expect(tiers[1].minDays, 7);
      expect(tiers[1].maxDays, isNull);
      expect(tierForDays(3, tiers)!.ratePct, 1.5);
      expect(tierForDays(8, tiers)!.ratePct, 0);
      expect(tierForDays(3000, tiers)!.ratePct, 0);
    });

    test('别的写法也认：「小于7天」「不低于30天」「持有期＜7天」', () {
      expect(tierFromRate(rate('小于7天', '1.5%'))!.maxDays, 7);
      expect(tierFromRate(rate('持有期＜7天', '1.5%'))!.maxDays, 7);
      final above = tierFromRate(rate('不低于30天', '0.5%'))!;
      expect(above.minDays, 30);
      expect(above.maxDays, isNull);
    });

    test('非赎回类型 / 非百分比费率 / 空条件 → 跳过', () {
      expect(
        tierFromRate(FundRate(
            type: 'purchase',
            chargeMode: 'front',
            condition: '100万元以下',
            standardRate: '1.20%')),
        isNull,
      );
      expect(tierFromRate(rate('500万元以上(包含)', '1000元/笔')), isNull);
      expect(tierFromRate(rate('', '1.5%')), isNull);
      expect(parseRedeemTiers(const []), isEmpty);
    });

    test('解析出来的表有缺口时退到上一档，不把费用算成 0', () {
      // 只回了「30天(包含)-365天」一档 → 400 天没有精确命中
      final tiers = parseRedeemTiers([rate('30天(包含)-365天', '0.50%')]);
      expect(tierForDays(400, tiers)!.ratePct, 0.5);
      expect(tierForDays(10, tiers)!.ratePct, 0.5, reason: '缺口里退到第一档，不返回 null');
    });

    test('空表 → null（调用方据此回落默认档）', () {
      expect(tierForDays(10, const []), isNull);
    });
  });

  group('档位表存取', () {
    test('JSON 往返；坏数据跳过', () {
      final json = kDefaultRedeemTiers.map((t) => t.toJson()).toList();
      final back = [
        for (final r in json) RedeemTier.fromJson(r),
      ];
      expect(back.length, 5);
      expect(back[0]!.minDays, 0);
      expect(back[0]!.maxDays, 7);
      expect(back[4]!.maxDays, isNull);
      expect(RedeemTier.fromJson('乱填'), isNull);
      expect(RedeemTier.fromJson({'min': 1}), isNull, reason: '缺费率要跳过');
    });

    test('改费率保留区间', () {
      final t = kDefaultRedeemTiers[2].copyWith(ratePct: 0.1);
      expect(t.minDays, 30);
      expect(t.maxDays, 365);
      expect(t.ratePct, 0.1);
    });
  });
}
