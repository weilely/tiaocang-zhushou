import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/rebalance_plan.dart';

/// 调仓页「净值 vs 估值模式」的判定
///
/// 用户报的 bug：「当日净值已经更新，调仓页面还是显示为估值模式」——
/// 根因是判定只看**历史库**（navSamples）最后一条是不是今天，而持仓/关注页
/// 显示的是**实时行情**里的当日净值。两边数据源不同步时就露馅了。
void main() {
  final today = DateTime(2026, 9, 18); // 用一个固定"今天"
  String key(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Quote q(String priceType, String infoDate, {double price = 1.5}) => Quote(
        code: '021362',
        kind: AssetKind.fund,
        priceType: priceType,
        infoDate: infoDate,
        price: price,
      );

  group('quoteHasTodaysNav：实时行情里是不是今天的已公布净值', () {
    test("priceType='nav' 且日期是今天 → 是", () {
      expect(quoteHasTodaysNav(q('nav', key(today)), today), isTrue);
    });

    test("priceType='est'（盘中估值）日期是今天 → **不是**（估值不等于已公布）", () {
      expect(quoteHasTodaysNav(q('est', key(today)), today), isFalse);
    });

    test("priceType='nav' 但日期是昨天 → 不是", () {
      final y = today.subtract(const Duration(days: 1));
      expect(quoteHasTodaysNav(q('nav', key(y)), today), isFalse);
    });

    test('价格为 0 的占位行情不算', () {
      expect(quoteHasTodaysNav(q('nav', key(today), price: 0), today), isFalse);
    });

    test('没有行情 → 不是', () {
      expect(quoteHasTodaysNav(null, today), isFalse);
    });

    test('infoDate 为空 / 解析不出来 → 不是', () {
      expect(quoteHasTodaysNav(q('nav', ''), today), isFalse);
      expect(quoteHasTodaysNav(q('nav', '乱填'), today), isFalse);
    });
  });

  group('navPublishedToday：今天是否已有真实净值', () {
    test('历史库最后一条就是今天 → 是', () {
      expect(
        navPublishedToday(quote: null, lastNavDate: key(today), now: today),
        isTrue,
      );
    });

    test('历史库是昨天、但实时行情已是今天的净值 → **仍然是**（这就是本次的 bug）', () {
      final y = today.subtract(const Duration(days: 1));
      expect(
        navPublishedToday(
          quote: q('nav', key(today)),
          lastNavDate: key(y),
          now: today,
        ),
        isTrue,
        reason: '只看历史库会让调仓页在"持仓页已显示当日净值"时停在估值模式',
      );
    });

    test('历史库是昨天、实时行情也只有盘中估值 → 不算是', () {
      final y = today.subtract(const Duration(days: 1));
      expect(
        navPublishedToday(
          quote: q('est', key(today)),
          lastNavDate: key(y),
          now: today,
        ),
        isFalse,
        reason: '盘中估值是估的，不能当成"净值已公布"',
      );
    });

    test('两边都没有今天的数据 → 不是', () {
      final y = today.subtract(const Duration(days: 1));
      expect(
        navPublishedToday(quote: q('nav', key(y)), lastNavDate: key(y), now: today),
        isFalse,
      );
      expect(navPublishedToday(quote: null, lastNavDate: null, now: today), isFalse);
    });
  });

  group('与 isFundEstMode 联起来：当日净值已公布就不该是估值模式', () {
    test('历史库今天有净值 → actual=true → 不是估值模式', () {
      final pub = navPublishedToday(
          quote: null, lastNavDate: key(today), now: today);
      final fq = resolveFundQuote(
        baseNav: 1.7,
        baseChangePct: 1.25,
        navPublishedToday: pub,
      );
      expect(fq.actual, isTrue);
      expect(fq.nav, closeTo(1.7, 1e-9));
      expect(
        isFundEstMode(navActual: fq.actual, estPct: 1.1, overridden: false),
        isFalse,
      );
    });

    test('只有实时净值、历史库还没落行 → 也算已公布，不该是估值模式', () {
      final y = today.subtract(const Duration(days: 1));
      final pub = navPublishedToday(
        quote: q('nav', key(today), price: 1.728),
        lastNavDate: key(y),
        now: today,
      );
      final fq = resolveFundQuote(
        baseNav: 1.728,
        baseChangePct: 1.25,
        navPublishedToday: pub,
      );
      expect(fq.actual, isTrue);
      expect(fq.nav, closeTo(1.728, 1e-9));
      expect(
        isFundEstMode(navActual: fq.actual, estPct: 1.25, overridden: false),
        isFalse,
        reason: '当日净值已更新 → 必须退出估值模式',
      );
    });

    test('确实没公布时，有估值依据才是估值模式', () {
      final y = today.subtract(const Duration(days: 1));
      final pub = navPublishedToday(
        quote: q('est', key(today)),
        lastNavDate: key(y),
        now: today,
      );
      expect(pub, isFalse);
      expect(
        isFundEstMode(navActual: false, estPct: 1.1, overridden: false),
        isTrue,
      );
      // 没有估值依据（联动 ETF 取不到）时不算估值模式
      expect(isFundEstMode(navActual: false, estPct: null, overridden: false),
          isFalse);
    });
  });
}
