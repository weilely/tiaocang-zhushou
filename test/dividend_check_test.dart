import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/dividend.dart';
import 'package:invest_tracker/logic/dividend_check.dart';

/// 分红核对的纯逻辑：**从净值提炼事件** + **对到账本上**
///
/// 用到的都是用户库里的真实形状（024564 两次分红、163402 一次折算、021362 从没分红）。
void main() {
  NavPoint nav(String date, double n, double acc, [String div = '']) =>
      NavPoint(code: 'x', date: date, nav: n, accNav: acc, dividend: div);

  Txn txn(TxnType type, String date, double amount,
          {double shares = 0, String note = ''}) =>
      Txn(
        accountId: 1,
        assetId: 9,
        type: type,
        date: DateTime.parse(date),
        amount: amount,
        shares: shares,
        note: note,
      );

  group('splitFactor：拆分文字的折算系数', () {
    test('真实原文「拆分：每份基金份额折算3.993900918份」→ 3.993900918', () {
      expect(splitFactor('拆分：每份基金份额折算3.993900918份'),
          closeTo(3.993900918, 1e-9));
    });

    test('分红文字里没有「折算」→ null', () {
      expect(splitFactor('分红：每份派现金0.008元'), isNull);
      expect(splitFactor(''), isNull);
    });
  });

  group('extractDividendEvents：从净值提炼事件', () {
    test('024564 的两次分红（真实数字）', () {
      final events = extractDividendEvents('024564', [
        nav('2026-04-09', 1.0100, 1.0100),
        nav('2026-04-10', 1.0000, 1.0100, '分红：每份派现金0.01元'),
        nav('2026-07-13', 0.9713, 0.9813),
        nav('2026-07-14', 0.9633, 0.9813, '分红：每份派现金0.008元'),
      ]);
      expect(events.length, 2);
      expect(events[0].date, '2026-04-10');
      expect(events[0].isSplit, isFalse);
      expect(events[0].perShare, closeTo(0.01, 1e-9));
      // ΔD = 0.010 − 0 = 0.010，与文字一致
      expect(events[0].deltaDiff, closeTo(0.01, 1e-9));
      expect(events[0].consistent, isTrue);

      expect(events[1].date, '2026-07-14');
      expect(events[1].perShare, closeTo(0.008, 1e-9));
      // ΔD = 0.018 − 0.010 = 0.008 ✓
      expect(events[1].deltaDiff, closeTo(0.008, 1e-9));
      expect(events[1].consistent, isTrue);
    });

    test('从没分过红（021362）：没有事件', () {
      final events = extractDividendEvents('021362', [
        nav('2026-09-17', 1.7066, 1.7066),
        nav('2026-09-18', 1.7280, 1.7280),
      ]);
      expect(events, isEmpty);
    });

    test('拆分事件：ΔD 与系数自洽（163402 真实数字）', () {
      final events = extractDividendEvents('163402', [
        // 拆分前一天：单位 3.9939、累计 4.0939（差 0.1 是历史分红）
        nav('2007-05-10', 3.9939, 4.0939),
        nav('2007-05-11', 1.0, 4.0939, '拆分：每份基金份额折算3.993900918份'),
      ]);
      expect(events.length, 1);
      expect(events.single.isSplit, isTrue);
      expect(events.single.perShare, closeTo(3.993900918, 1e-9));
      // ΔD = 3.0939 − 0.1 = 2.9939 = (3.9939−1)×1.0 ✓
      expect(events.single.deltaDiff, closeTo(2.9939, 1e-4));
      expect(events.single.consistent, isTrue);
    });

    test('没有累计净值（accNav=0）时，事件照样给，但标"未互验"', () {
      final events = extractDividendEvents('510300', [
        nav('2026-01-05', 4.0, 0, '分红：每份派现金0.05元'),
      ]);
      expect(events.single.deltaDiff, isNull);
      expect(events.single.consistent, isNull, reason: '验不了就说验不了');
    });

    test('认不出的文字跳过（不猜）', () {
      final events = extractDividendEvents('x', [
        nav('2026-01-05', 1.0, 1.0, '分红：每份派现金0元'),
        nav('2026-01-06', 1.0, 1.0, '每份分0.03'),
      ]);
      expect(events, isEmpty);
    });
  });

  group('checkDividends：对到账本上', () {
    final navs = [
      nav('2026-07-13', 0.9713, 0.9813),
      nav('2026-07-14', 0.9633, 0.9813, '分红：每份派现金0.008元'),
    ];

    test('红利再投已记（cashless 买入、备注带「红利再投」）→ 对上', () {
      final rows = checkDividends(
        code: '024564',
        assetName: '易方达中证红利价值ETF联接A',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [
          txn(TxnType.buy, '2026-01-05', 10000, shares: 10000, note: '买入'),
          // 与 App 自己补记的写法一致：金额 = 每份×份额，份额 = 金额 ÷ 除息日净值
          txn(TxnType.buy, '2026-07-14', 80.0,
              shares: 83.05, note: '红利再投 2026-07-14'),
        ],
      );
      expect(rows.single.status, DivCheckStatus.reinvestRecorded);
      expect(rows.single.shares, closeTo(10000, 1e-9));
      expect(rows.single.expectAmount, closeTo(80.0, 1e-6));
      expect(rows.single.expectShares, closeTo(80.0 / 0.9633, 1e-6));
    });

    test('现金分红已记 → 对上', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [
          txn(TxnType.buy, '2026-01-05', 10000, shares: 10000),
          txn(TxnType.dividend, '2026-07-15', 80.0, note: '分红自动 2026-07-14'),
        ],
      );
      expect(rows.single.status, DivCheckStatus.cashRecorded);
    });

    test('什么都没记 → 缺记，并给出应补的金额与份额', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [txn(TxnType.buy, '2026-01-05', 10000, shares: 10000)],
      );
      final r = rows.single;
      expect(r.status, DivCheckStatus.missing);
      expect(r.expectAmount, closeTo(80.0, 1e-6));
      expect(r.expectShares, closeTo(83.05, 0.01));
    });

    test('记了但金额差很多 → 对不上', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [
          txn(TxnType.buy, '2026-01-05', 10000, shares: 10000),
          txn(TxnType.dividend, '2026-07-15', 8.0, note: '手记'),
        ],
      );
      expect(rows.single.status, DivCheckStatus.mismatch);
      expect(rows.single.foundAmount, 8.0);
    });

    test('除息日之后才买入 → 与你无关（notHeld）', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [txn(TxnType.buy, '2026-08-01', 10000, shares: 10000)],
      );
      expect(rows.single.status, DivCheckStatus.notHeld);
    });

    test('账本份额为负（卖得比买的多）→ ledgerShort，而不是"与你无关"', () {
      // 真实形状：前面某次红利再投没记份额 → 后来把实际持有的全卖了 → 账本短缺 305.07 份
      final rows = checkDividends(
        code: '020602',
        assetName: '易方达中证红利低波动ETF联接A',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: [
          nav('2026-09-09', 1.07, 1.08),
          nav('2026-09-10', 1.06, 1.08, '分红：每份派现金0.011元'),
        ],
        txns: [
          txn(TxnType.buy, '2026-01-05', 36500, shares: 34106.85),
          txn(TxnType.sell, '2026-06-01', 36000, shares: 34411.92), // 卖了实际份额
        ],
      );
      final r = rows.single;
      expect(r.status, DivCheckStatus.ledgerShort);
      expect(r.shares, closeTo(-305.07, 0.05));
      expect(r.expectAmount, 0, reason: '份额本身是错的，金额算不出来就别编');
    });

    test('除息日当天买入：不算"持有"，但要提示当天有交易', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [txn(TxnType.buy, '2026-07-14', 10000, shares: 10000)],
      );
      expect(rows.single.status, DivCheckStatus.notHeld);
      expect(rows.single.tradedOnExDate, isTrue);
    });

    test('拆分事件 → 只提示份额应变成多少（不是钱的事）', () {
      final rows = checkDividends(
        code: '163402',
        assetName: '兴全趋势',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: [
          nav('2007-05-10', 3.9939, 4.0939),
          nav('2007-05-11', 1.0, 4.0939, '拆分：每份基金份额折算3.993900918份'),
        ],
        txns: [txn(TxnType.buy, '2006-01-05', 10000, shares: 1000)],
      );
      final r = rows.single;
      expect(r.status, DivCheckStatus.split);
      expect(r.expectShares, closeTo(1000 * 3.993900918, 0.01));
    });

    test('分红方式：生效日之前的事件不按当前设置建议（历史方式未知）', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [txn(TxnType.buy, '2026-01-05', 10000, shares: 10000)],
        mode: 'reinvest',
        modeFrom: DateTime.parse('2026-09-01'), // 设置晚于这次分红
      );
      expect(rows.single.modeApplies, isFalse);
      expect(rows.single.suggestedMode, '');
    });

    test('生效日之后的事件可以按当前设置建议', () {
      final rows = checkDividends(
        code: '024564',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: navs,
        txns: [txn(TxnType.buy, '2026-01-05', 10000, shares: 10000)],
        mode: 'reinvest',
        modeFrom: DateTime.parse('2026-06-01'),
      );
      expect(rows.single.modeApplies, isTrue);
      expect(rows.single.suggestedMode, 'reinvest');
    });

    test('金额容差：差 2 分钱以内算对上（分红到账有时四舍五入）', () {
      expect(closeEnough(80.0, 80.02), isTrue);
      expect(closeEnough(80.0, 82.0), isFalse);
      expect(closeEnough(10000, 10030), isTrue, reason: '0.3% 在容差内');
    });

    test('残份额造成的分币级分红不列（低于 ¥1 直接跳过）', () {
      final rows = checkDividends(
        code: '020602',
        assetName: 'x',
        accountName: '账户A',
        accountId: 1,
        assetId: 9,
        navs: [
          nav('2026-09-09', 1.07, 1.08),
          nav('2026-09-10', 1.06, 1.08, '分红：每份派现金0.011元'),
        ],
        // 卖出后只剩 0.92 份 → 应得 0.01 元，纯噪声
        txns: [
          txn(TxnType.buy, '2026-01-05', 36500, shares: 34106.85),
          txn(TxnType.sell, '2026-06-01', 36000, shares: 34105.93),
        ],
      );
      expect(rows, isEmpty);
    });
  });

  group('recommendedModeFor：补记用哪种方式（用户拍板"按推荐方式补记"）', () {
    DivCheckRow row({String mode = '', DateTime? from}) => checkDividends(
          code: '024564',
          assetName: 'x',
          accountName: '账户A',
          accountId: 1,
          assetId: 9,
          navs: [
            nav('2026-07-13', 0.9713, 0.9813),
            nav('2026-07-14', 0.9633, 0.9813, '分红：每份派现金0.008元'),
          ],
          txns: [txn(TxnType.buy, '2026-01-05', 10000, shares: 10000)],
          mode: mode,
          modeFrom: from,
        ).single;

    test('没设过分红方式（历史方式未知）→ 推荐红利再投', () {
      expect(recommendedModeFor(row()), DividendMode.reinvest);
    });

    test('设置生效日在这次分红之后 → 仍然推荐红利再投（不拿当前设置套历史）', () {
      expect(recommendedModeFor(row(mode: 'cash', from: DateTime.parse('2026-09-01'))),
          DividendMode.reinvest);
    });

    test('设置生效日在这次分红之前 → 就用他明确定的方式', () {
      expect(recommendedModeFor(row(mode: 'cash', from: DateTime.parse('2026-06-01'))),
          DividendMode.cash);
      expect(
          recommendedModeFor(
              row(mode: 'reinvest', from: DateTime.parse('2026-06-01'))),
          DividendMode.reinvest);
    });
  });
}
