import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/nav_lookup.dart';

/// 「按交易日期查净值」的口径
///
/// 这套规则决定了买入/卖出表单里那个净值是从哪儿来的，所以逐条钉住：
/// 精确 → 顺延（非交易日下单在下一交易日成交）→ 回退（今天还没出净值）。
void main() {
  // 固定一组日期当坐标系：09-11 周五、09-12 周六、09-14 周一
  final fri = DateTime(2026, 9, 11);
  final sat = DateTime(2026, 9, 12);
  final mon = DateTime(2026, 9, 14);

  setUpAll(() {
    // 前提先自检：日期对不对会直接让下面的用例失去意义
    expect(fri.weekday, DateTime.friday);
    expect(sat.weekday, DateTime.saturday);
    expect(mon.weekday, DateTime.monday);
  });

  group('pickNavFill', () {
    test('所选日期精确命中，用当天', () {
      final f = pickNavFill(
        day: fri,
        today: mon,
        local: {'2026-09-10': 1.70, '2026-09-11': 1.7248, '2026-09-14': 1.73},
      );
      expect(f, isNotNull);
      expect(f!.nav, 1.7248);
      expect(f.date, '2026-09-11');
      expect(f.exact, isTrue);
    });

    test('周六下单：顺延到下一个交易日（周一），不是回退到周五', () {
      final f = pickNavFill(
        day: sat,
        today: mon,
        local: {'2026-09-11': 1.7248, '2026-09-14': 1.7602},
      );
      expect(f!.nav, 1.7602);
      expect(f.date, '2026-09-14');
      expect(f.exact, isFalse);
    });

    test('今天还没出净值：回退到上一个交易日', () {
      final f = pickNavFill(
        day: mon,
        today: mon,
        local: {'2026-09-11': 1.7248},
      );
      expect(f!.nav, 1.7248);
      expect(f.date, '2026-09-11');
      expect(f.exact, isFalse);
    });

    test('今天是今天且有当日行情：行情优先于前一日净值', () {
      final f = pickNavFill(
        day: mon,
        today: mon,
        local: {'2026-09-11': 1.7248},
        quote: (price: 1.7520, date: '2026-09-14', estimated: true),
      );
      expect(f!.nav, 1.7520);
      expect(f.date, '2026-09-14');
      expect(f.exact, isTrue);
      expect(f.estimated, isTrue);
    });

    test('非今天时行情不参与（历史日期只认历史数据）', () {
      final f = pickNavFill(
        day: fri,
        today: mon,
        local: {'2026-09-11': 1.7248},
        quote: (price: 1.7520, date: '2026-09-14', estimated: false),
      );
      expect(f!.nav, 1.7248);
      expect(f.date, '2026-09-11');
    });

    test('场内标的：今天的市价优先于同日净值（场内按市价成交）', () {
      final f = pickNavFill(
        day: mon,
        today: mon,
        local: {'2026-09-14': 4.5489}, // 基金净值
        quote: (price: 4.5520, date: '2026-09-14', estimated: false), // 交易所收盘
        preferQuote: true,
      );
      expect(f!.nav, 4.5520);
      expect(f.date, '2026-09-14');
      expect(f.exact, isTrue);
      expect(f.estimated, isFalse);
    });

    test('场外基金：同日已公布净值优先于盘中估值', () {
      final f = pickNavFill(
        day: mon,
        today: mon,
        local: {'2026-09-14': 1.7548},
        quote: (price: 1.7520, date: '2026-09-14', estimated: true),
        preferQuote: false,
      );
      expect(f!.nav, 1.7548);
      expect(f.estimated, isFalse);
    });

    test('行情日期不是所选日期时，不可冒充当天', () {
      final f = pickNavFill(
        day: mon,
        today: mon,
        local: {'2026-09-14': 4.5489},
        quote: (price: 4.5794, date: '2026-09-11', estimated: false),
        preferQuote: true,
      );
      expect(f!.nav, 4.5489); // 要那天的净值，不要隔夜的行情
      expect(f.date, '2026-09-14');
    });

    test('联网值与本地同一天时以联网为准', () {
      final f = pickNavFill(
        day: fri,
        today: mon,
        local: {'2026-09-11': 1.7000},
        remote: {'2026-09-11': 1.7248},
      );
      expect(f!.nav, 1.7248);
      expect(f.exact, isTrue);
    });

    test('本地没有、联网有：用联网的', () {
      final f = pickNavFill(
        day: sat,
        today: mon,
        local: const {},
        remote: {'2026-09-14': 1.7602},
      );
      expect(f!.nav, 1.7602);
      expect(f.exact, isFalse);
    });

    test('顺延不得越过今天：明天还没有净值', () {
      final tomorrow = DateTime(2026, 9, 15);
      final f = pickNavFill(
        day: tomorrow,
        today: mon,
        local: {'2026-09-14': 1.76},
      );
      // 只能回退到今天（09-14），而不是假装明天有价
      expect(f!.date, '2026-09-14');
      expect(f.exact, isFalse);
    });

    test('什么都没有就返回 null（交给界面提示手工填写）', () {
      final f = pickNavFill(day: sat, today: mon, local: const {});
      expect(f, isNull);
    });

    test('0 与负数视为无效值，不参与取价', () {
      final f = pickNavFill(
        day: fri,
        today: mon,
        local: {'2026-09-11': 0, '2026-09-10': -1.2},
      );
      expect(f, isNull);
    });
  });

  group('hasExactNav', () {
    test('有当天净值才是精确命中', () {
      expect(hasExactNav({'2026-09-11': 1.72}, fri), isTrue);
      expect(hasExactNav({'2026-09-11': 1.72}, sat), isFalse);
      expect(hasExactNav({'2026-09-11': 0}, fri), isFalse);
      expect(hasExactNav(const {}, fri), isFalse);
    });
  });

  group('navFillHint', () {
    test('查询中', () {
      expect(
        navFillHint(day: sat, busy: true),
        '正在查询 2026年09月12日 的净值…',
      );
    });

    test('精确命中显示净值所属日期', () {
      const f = NavFill(nav: 1.7248, date: '2026-09-11', exact: true);
      expect(navFillHint(day: fri, fill: f), '2026-09-11 净值 1.7248');
    });

    test('估值单独标注', () {
      const f = NavFill(
          nav: 1.7520, date: '2026-09-14', exact: true, estimated: true);
      expect(navFillHint(day: mon, fill: f), '2026-09-14 盘中估值 1.7520');
    });

    test('顺延/回退要说清取的是哪一天', () {
      const f = NavFill(nav: 1.7602, date: '2026-09-14', exact: false);
      expect(navFillHint(day: sat, fill: f), '该日无净值，取 09-14 净值 1.7602');
    });

    test('查不到：区分「本来就查不到」和「联网失败」', () {
      expect(
        navFillHint(day: sat),
        '未查到 2026年09月12日 的净值，请手工填写',
      );
      expect(
        navFillHint(day: sat, error: '网络错误：SocketException'),
        '联网查询失败，可手工填写净值',
      );
    });

    test('还没填代码时是中性的待查询，不是错误', () {
      expect(
        navFillHint(day: sat, hasCode: false),
        '填入代码后自动按日期查净值',
      );
      // 没代码时不显示任何失败文案
      expect(navFillHint(day: sat, hasCode: false, error: 'x'),
          isNot(contains('失败')));
    });

    test('填了代码但还没查过，也不该报「未查到」', () {
      expect(
        navFillHint(day: sat, queried: false),
        '选中标的后自动按日期查净值',
      );
      expect(navFillHint(day: sat, queried: false), isNot(contains('未查到')));
    });
  });
}
