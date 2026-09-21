import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/nav_freshness.dart';

/// 「历史净值落后就补」的判断
///
/// 用户报的 bug：「收益统计昨天 9-21 没有收益数据」——
/// `nav_history` 停在 09-18，而实时行情里 09-21 的已公布净值早就有了，
/// 因为净值历史的更新是"一天只跑一次、错过不补"。
void main() {
  QuoteNavInfo q(String priceType, String infoDate) =>
      (priceType: priceType, infoDate: infoDate);

  group('该补的：行情有更新的已公布净值、历史表没跟上', () {
    test('历史停在 09-18、行情是 09-21 的净值 → 要补（这就是本次的 bug 场景）', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': '2026-09-18'},
        quotes: {'021362': q('nav', '2026-09-21')},
      );
      expect(got, ['021362']);
    });

    test('历史表里根本没有这只 → 也要补', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': null},
        quotes: {'021362': q('nav', '2026-09-21')},
      );
      expect(got, ['021362']);
    });

    test('多只一起判断，只挑出落后的那些', () {
      final got = staleNavCodes(
        historyLastDate: {
          'A': '2026-09-18',
          'B': '2026-09-21',
          'C': null,
        },
        quotes: {
          'A': q('nav', '2026-09-21'),
          'B': q('nav', '2026-09-21'),
          'C': q('nav', '2026-09-21'),
        },
      );
      expect(got, ['A', 'C']);
    });
  });

  group('不该补的（别白跑网络）', () {
    test('历史已经和行情同日 → 不补', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': '2026-09-21'},
        quotes: {'021362': q('nav', '2026-09-21')},
      );
      expect(got, isEmpty);
    });

    test('历史比行情还新 → 不补', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': '2026-09-22'},
        quotes: {'021362': q('nav', '2026-09-21')},
      );
      expect(got, isEmpty);
    });

    test('行情是「盘中估值」est → 不算（估值不是真净值，不能写进历史）', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': '2026-09-18'},
        quotes: {'021362': q('est', '2026-09-22')},
      );
      expect(got, isEmpty);
    });

    test('行情日期解析不出来 → 不动', () {
      final got = staleNavCodes(
        historyLastDate: {'021362': '2026-09-18'},
        quotes: {'021362': q('nav', '')},
      );
      expect(got, isEmpty);
      final got2 = staleNavCodes(
        historyLastDate: {'021362': '2026-09-18'},
        quotes: {'021362': q('nav', '乱填')},
      );
      expect(got2, isEmpty);
    });

    test('没有行情 / 没有历史都没有 → 不补', () {
      expect(
        staleNavCodes(historyLastDate: const {}, quotes: const {}),
        isEmpty,
      );
    });

    test('交易所现价 price 不算净值', () {
      final got = staleNavCodes(
        historyLastDate: {'510300': '2026-09-18'},
        quotes: {'510300': q('price', '2026-09-22')},
      );
      expect(got, isEmpty);
    });
  });

  group('输出稳定', () {
    test('结果按代码排序（便于测试与日志对比）', () {
      final got = staleNavCodes(
        historyLastDate: {'C': null, 'A': null, 'B': '2026-09-01'},
        quotes: {
          'C': q('nav', '2026-09-21'),
          'A': q('nav', '2026-09-21'),
          'B': q('nav', '2026-09-21'),
        },
      );
      expect(got, ['A', 'B', 'C']);
    });
  });
}
