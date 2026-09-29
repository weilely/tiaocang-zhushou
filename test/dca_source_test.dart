import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:invest_tracker/data/dca_source.dart';
import 'package:invest_tracker/data/market_api.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/dca.dart';

/// 定投补记的取价层
///
/// 用户 2026-09-30：「我就想通过定投生成历史记录，结果不管用」——根因是
/// `f10/lsjz` 的 `pageSize` **硬上限 20 条**（写 200 也只回 20），而且回的是
/// 窗口里**最新**的 20 条；计划起始日在两年前时最早的期数一条价都取不到。
/// 这组用例守住修法：先走 pingzhongdata（一次全量），退回 lsjz 时**必须翻页**。
void main() {
  group('coversAllDue：这批价够不够算完每一期', () {
    final today = DateTime(2026, 9, 30);

    test('每期都在窗口内有价 → 够', () {
      final prices = {
        '2026-09-01': 1.0, // 应投日当天
        '2026-09-05': 1.1, // 09-03 顺延到 09-05
      };
      expect(
        coversAllDue([DateTime(2026, 9, 1), DateTime(2026, 9, 3)], prices, today),
        isTrue,
      );
    });

    test('有一期整段窗口都没价 → 不够（要去取）', () {
      final prices = {'2026-09-01': 1.0};
      expect(
        coversAllDue(
            [DateTime(2026, 9, 1), DateTime(2026, 8, 1)], prices, today),
        isFalse,
        reason: '8/1 那期在 8/1~8/13 里没有任何价',
      );
    });

    test('空价格表 → 不够', () {
      expect(coversAllDue([DateTime(2026, 9, 1)], const {}, today), isFalse);
    });
  });

  group('lsjzPaged：每页 20 条也要翻到覆盖住窗口起点', () {
    /// 造一个"本地假接口"：按 pageIndex 返回 20 条一页，日期从新到旧
    MockClient pagedServer({required int totalDays, required List<int> hits}) =>
        MockClient((req) async {
          final page = int.tryParse(req.url.queryParameters['pageIndex'] ?? '1') ?? 1;
          hits.add(page);
          final end = DateTime(2026, 9, 30);
          final rows = <Map<String, String>>[];
          for (var i = 0; i < 20; i++) {
            final idx = (page - 1) * 20 + i;
            if (idx >= totalDays) break;
            final d = end.subtract(Duration(days: idx));
            final key = '${d.year.toString().padLeft(4, '0')}-'
                '${d.month.toString().padLeft(2, '0')}-'
                '${d.day.toString().padLeft(2, '0')}';
            rows.add({'FSRQ': key, 'DWJZ': '1.0000'});
          }
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'ErrCode': 0,
              'Data': {'LSJZList': rows},
            })),
            200,
          );
        });

    test('窗口很长时会一直翻，直到覆盖住起点', () async {
      final hits = <int>[];
      // 共 60 天数据、窗口要 45 天 → 需要 3 页（20+20+20）
      final src = DcaPriceSource(pagedServer(totalDays: 60, hits: hits));
      final from = DateTime(2026, 9, 30).subtract(const Duration(days: 45));
      final m = await src.lsjzPaged('021362', from, DateTime(2026, 9, 30));

      expect(hits.length, greaterThanOrEqualTo(3), reason: '必须翻页，不能只看第一页');
      expect(m.length, greaterThanOrEqualTo(20),
          reason: '只回第一页的 20 条就是原来那个 bug（补历史时一条价都取不到）');
      final dates = m.keys.toList()..sort();
      expect(dates.first.compareTo('2026-08-16') <= 0, isTrue,
          reason: '要覆盖到窗口起点附近，实际最早 ${dates.first}');
      src.dispose();
    });

    test('数据只有一页时不会白翻第二次', () async {
      final hits = <int>[];
      final src = DcaPriceSource(pagedServer(totalDays: 5, hits: hits));
      final from = DateTime(2026, 9, 1);
      await src.lsjzPaged('021362', from, DateTime(2026, 9, 30));
      expect(hits, [1], reason: '第一页就不满 20 条 → 到底了，停');
      src.dispose();
    });

    test('第一页报错要抛（ErrCode != 0），翻到后面报错就当拿到多少算多少', () async {
      final src = DcaPriceSource(MockClient((req) async {
        final page = req.url.queryParameters['pageIndex'];
        if (page == '1') {
          return http.Response.bytes(
              utf8.encode(jsonEncode({'ErrCode': -999})), 200);
        }
        return http.Response.bytes(
            utf8.encode(jsonEncode({'ErrCode': -999})), 200);
      }));
      expect(
        () => src.lsjzPaged('021362', DateTime(2026, 1, 1), DateTime(2026, 9, 30)),
        throwsA(isA<MarketException>()),
      );
      src.dispose();
    });
  });

  group('fundHistory：优先走 pingzhongdata（一次全量）', () {
    test('pingzhongdata 有数据时不碰 lsjz', () async {
      final urls = <String>[];
      final src = DcaPriceSource(MockClient((req) async {
        urls.add(req.url.host + req.url.path);
        // pingzhongdata 的返回形状：两段 JS 数组
        const body = 'var Data_netWorthTrend = ['
            '{"x":1789056000000,"y":1.7637,"equityReturn":0,"unitMoney":""},'
            '{"x":1789315200000,"y":1.7548,"equityReturn":0,"unitMoney":""}'
            '];var Data_ACWorthTrend = [[1789315200000,1.7548]];';
        return http.Response.bytes(utf8.encode(body), 200);
      }));

      final a = Asset(code: '021362', name: 'x', kind: AssetKind.fund);
      final m = await src.fundHistory('021362',
          DateTime(2026, 9, 1), DateTime(2026, 9, 30), asset: a);
      expect(m.isNotEmpty, isTrue);
      expect(urls.every((u) => u.contains('pingzhongdata')), isTrue,
          reason: '拿到全量了就不该再去翻 lsjz');
      src.dispose();
    });
  });
}
