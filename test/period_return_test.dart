import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/data/nav_source.dart';
import 'package:invest_tracker/logic/period_return.dart';

NavPoint p(String date, double nav, {double? acc, double chg = 0, String div = ''}) =>
    NavPoint(code: 'x', date: date, nav: nav, accNav: acc ?? nav, changePct: chg, dividend: div);

void main() {
  group('区间收益', () {
    // 2025-01-01 起每 30 天一个点，共 13 个点（覆盖约 1 年）
    List<NavPoint> year() {
      final out = <NavPoint>[];
      var d = DateTime(2025, 1, 1);
      for (var i = 0; i < 13; i++) {
        out.add(p(
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
          1.0 + i * 0.01,
        ));
        d = d.add(const Duration(days: 30));
      }
      return out;
    }

    test('近1周：取 7 天前之前最近的一条', () {
      final pts = year();
      final r = periodReturn(pts, ReturnPeriod.w1, asOf: DateTime(2026, 1, 1));
      expect(r, isNotNull);
      // 起点应是 12-25 之前最近的点（12-16 左右），收益为正
      expect(r!, greaterThan(0));
    });

    test('历史长度不足该区间 → null（界面显示 --）', () {
      final pts = year();
      expect(periodReturn(pts, ReturnPeriod.y5, asOf: DateTime(2026, 1, 1)), isNull);
      expect(periodReturn(pts, ReturnPeriod.y3, asOf: DateTime(2026, 1, 1)), isNull);
    });

    test('成立以来：从最早一条算起', () {
      final pts = year();
      final r = periodReturn(pts, ReturnPeriod.inception, asOf: DateTime(2026, 1, 1));
      expect(r, isNotNull);
      expect(r!, closeTo((1.12 / 1.0 - 1) * 100, 1e-6));
    });

    test('起点日没有记录时，取该日之前最近的有价日', () {
      // 只有 01-01 与 01-20 两个点，查「近1周」相对 01-20 → 目标 01-13，
      // 01-13 无数据 → 取 01-01
      final pts = [p('2025-01-01', 1.0), p('2025-01-20', 1.1)];
      final r = periodReturn(pts, ReturnPeriod.w1, asOf: DateTime(2025, 1, 20));
      expect(r, closeTo(10.0, 1e-6));
    });

    test('用累计净值计算：分红前后收益连续', () {
      // 单位净值因分红下跌，但累计净值连续
      final pts = [
        p('2025-01-01', 1.00, acc: 1.00),
        p('2025-06-01', 1.10, acc: 1.10),
        p('2025-06-02', 1.00, acc: 1.10, div: '每份派现金0.1元'), // 分红，净值回落
        p('2025-12-31', 1.20, acc: 1.32),
      ];
      final r = periodReturn(pts, ReturnPeriod.inception, asOf: DateTime(2025, 12, 31));
      // (1.32/1.00 - 1) = 32%
      expect(r, closeTo(32.0, 1e-6));
    });

    test('少于两条记录返回 null', () {
      expect(periodReturn([p('2025-01-01', 1.0)], ReturnPeriod.w1), isNull);
      expect(periodReturn(const [], ReturnPeriod.w1), isNull);
    });

    test('formatReturnPct：null 显示 --，正负带符号', () {
      expect(formatReturnPct(null), '--');
      expect(formatReturnPct(12.345), '+12.35%');
      expect(formatReturnPct(-3.5), '-3.50%');
      expect(formatReturnPct(0), '0.00%');
    });

    test('latestNav 取日期最大的一条', () {
      expect(latestNav([p('2025-01-01', 1.0), p('2025-06-01', 1.5)]), 1.5);
      expect(latestNav(const []), isNull);
    });

    test('latestPoint 连日期一起给出（净值列要在净值下方显示它）', () {
      final last = latestPoint([p('2025-01-01', 1.0), p('2025-06-01', 1.5)]);
      expect(last, isNotNull);
      expect(last!.nav, 1.5);
      expect(last.date, '2025-06-01');
      expect(latestPoint(const []), isNull);
    });

    test('latestPoint 对乱序输入也取对', () {
      final last = latestPoint([
        p('2025-06-01', 1.5),
        p('2025-01-01', 1.0),
        p('2024-12-31', 0.9),
      ]);
      expect(last!.date, '2025-06-01');
      expect(last.nav, 1.5);
    });

    test('latestNav 与 latestPoint 始终一致', () {
      final pts = [p('2025-03-01', 1.2), p('2025-01-01', 1.0)];
      expect(latestNav(pts), latestPoint(pts)!.nav);
    });
  });

  // 名称缩略规则已从 `WatchItem.shortName`（固定「前4字…末字」）搬到
  // `ReturnTable` 的 `fitName()`：现在按**真实渲染宽度**测量，放得下就完整显示，
  // 放不下才从中间省略且保留末字符。断言见 test/code_name_fit_test.dart。

  group('大盘指数预设', () {
    test('默认显示前 3 个', () {
      expect(MarketIndex.defaultCodes,
          ['sh000001', 'sz399001', 'sz399006']);
      // 8 个 A 股指数 + 1 个黄金（上金所现货；沪金主连已按用户要求删除）
      expect(MarketIndex.presets.length, 9);
      expect(MarketIndex.byCode('sh000001')!.name, '上证指数');
      // 非沪深品种用 `em:<东财 secid>` 直连：黄金9999 = 118.AU9999
      expect(MarketIndex.byCode('em:118.AU9999')!.name, '黄金9999');
      // 沪金主连（113.aum）已删除：东财挂了它没有备用源，只会显示 --
      expect(MarketIndex.byCode('em:113.aum'), isNull);
      // `em:` 代码必须单独一类，否则会被拼成 0.em:... 这种错的市场号
      expect(const IndexEntry(code: 'em:118.AU9999').group, 'other');
      expect(const IndexEntry(code: 'sh000001').group, 'broad');
      expect(const IndexEntry(code: 'sz399006').group, 'broad');
    });
  });

  group('净值数据源解析', () {
    test('pingzhongdata：净值与累计净值按时间戳对齐、unitMoney 记为分红', () async {
      const ts1 = 1735689600000; // 2025-01-01
      const ts2 = 1735776000000; // 2025-01-02
      final body = 'var fS_name = "测试基金";'
          'var Data_netWorthTrend = '
          '[{"x":$ts1,"y":1.0,"equityReturn":0,"unitMoney":""},'
          '{"x":$ts2,"y":1.1,"equityReturn":10,"unitMoney":"每份派现金0.1元"}];'
          'var Data_ACWorthTrend = [[$ts1,1.0],[$ts2,1.2]];';

      final src = NavSource(
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)));
      final pts = await src.fullHistory(
          Asset(code: '000001', name: '', kind: AssetKind.fund));

      expect(pts.length, 2);
      expect(pts.first.nav, closeTo(1.0, 1e-9));
      expect(pts.first.accNav, closeTo(1.0, 1e-9));
      expect(pts.last.nav, closeTo(1.1, 1e-9));
      expect(pts.last.accNav, closeTo(1.2, 1e-9), reason: '累计净值要对齐到同一天');
      expect(pts.last.changePct, closeTo(10, 1e-9));
      expect(pts.first.hasDividend, isFalse);
      expect(pts.last.hasDividend, isTrue);
      expect(pts.last.value, closeTo(1.2, 1e-9), reason: '计算收益要用累计净值');
      src.dispose();
    });

    test('lsjz：ErrCode -999 判为失败，不返回空数据', () async {
      final src = NavSource(MockClient((_) async =>
          http.Response.bytes(utf8.encode('{"Data":"","ErrCode":-999}'), 200)));
      await expectLater(
        src.recentHistory(
            Asset(code: '000001', name: '', kind: AssetKind.fund)),
        throwsA(isA<Exception>()),
      );
      src.dispose();
    });

    test('lsjz：遇到本地已有日期即停（增量）', () async {
      final body = '{"Data":{"LSJZList":['
          '{"FSRQ":"2026-09-14","DWJZ":"1.20","LJJZ":"1.30","JZZZL":"1.0","FHFCZ":""},'
          '{"FSRQ":"2026-09-13","DWJZ":"1.19","LJJZ":"1.29","JZZZL":"0.5","FHFCZ":""},'
          '{"FSRQ":"2026-09-11","DWJZ":"1.18","LJJZ":"1.28","JZZZL":"0.1","FHFCZ":""}'
          ']},"ErrCode":0}';
      final src = NavSource(
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)));
      final pts = await src.recentHistory(
          Asset(code: '000001', name: '', kind: AssetKind.fund),
          stopDate: '2026-09-11');
      expect(pts.length, 2, reason: '09-11 已有，只应返回 09-13 与 09-14');
      expect(pts.first.date, '2026-09-13');
      expect(pts.last.date, '2026-09-14');
      src.dispose();
    });

    test('新浪指数精简格式解析并保持请求顺序', () async {
      final body = 'var hq_str_s_sz399001="深证成指,13471.26,-146.413,-1.08,1,2";\n'
          'var hq_str_s_sh000001="上证指数,3888.1106,-46.2930,-1.18,3,4";\n';
      final src = NavSource(MockClient((_) async =>
          http.Response.bytes(utf8.encode(body), 200)));
      final qs = await src.indexQuotes(['sh000001', 'sz399001']);
      expect(qs.length, 2);
      expect(qs.first.code, 'sh000001', reason: '顺序应按请求顺序');
      expect(qs.first.name, '上证指数');
      expect(qs.first.price, closeTo(3888.1106, 1e-6));
      expect(qs.first.changePct, closeTo(-1.18, 1e-9));
      src.dispose();
    });
  });
}
