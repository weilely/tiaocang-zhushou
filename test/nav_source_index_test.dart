import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:invest_tracker/core/format.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_source.dart';

/// 抓取层：指数代码放行 + 增量更新按标的分流
///
/// 分流修的是一个既有缺陷：以前所有标的历史非空时都调基金专用的 `lsjz`，
/// 纯股票（如 600519）会一直失败，入库后再也无法增量更新。
void main() {
  group('新浪代码：预设指数原样放行', () {
    Future<String> requestedSymbol(Asset a) async {
      late Uri seen;
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(utf8.encode('[]'), 200);
      }));
      await src.sinaDaily(a);
      src.dispose();
      return seen.queryParameters['symbol'] ?? '';
    }

    test('8 位带市场前缀的预设指数代码直接使用', () async {
      expect(
        await requestedSymbol(
            Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other)),
        'sh000300',
      );
      expect(
        await requestedSymbol(
            Asset(code: 'sz399006', name: '创业板指', kind: AssetKind.other)),
        'sz399006',
      );
      expect(
        await requestedSymbol(
            Asset(code: 'bj899050', name: '北证50', kind: AssetKind.other)),
        'bj899050',
      );
    });

    test('6 位代码仍按原来的市场规则拼前缀', () async {
      expect(
        await requestedSymbol(
            Asset(code: '600519', name: '贵州茅台', kind: AssetKind.stock, market: 'SH')),
        'sh600519',
      );
      expect(
        await requestedSymbol(
            Asset(code: '000001', name: '平安银行', kind: AssetKind.stock, market: 'SZ')),
        'sz000001',
      );
      // 没写 market 时按代码段推断
      expect(
        await requestedSymbol(
            Asset(code: '300750', name: '宁德时代', kind: AssetKind.stock)),
        'sz300750',
      );
      expect(
        await requestedSymbol(
            Asset(code: '688981', name: '中芯国际', kind: AssetKind.stock)),
        'sh688981',
      );
    });

    test('既不是 6 位也不是预设 8 位 → 报错而不是乱拼', () async {
      final src = NavSource(MockClient((_) async =>
          http.Response.bytes(utf8.encode('[]'), 200)));
      await expectLater(
        src.sinaDaily(Asset(code: 'abc', name: '', kind: AssetKind.other)),
        throwsA(isA<Exception>()),
      );
      src.dispose();
    });

    test('指数传 datalen=1500（实测上限，2000 会返回空）', () async {
      late Uri seen;
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(utf8.encode('[]'), 200);
      }));
      await src.fullHistory(
          Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other),
          datalen: 1500);
      expect(seen.queryParameters['datalen'], '1500');
      src.dispose();
    });
  });

  group('增量更新按标的分流', () {
    test('基金走 lsjz', () async {
      late Uri seen;
      const page1 = '{"Data":{"LSJZList":['
          '{"FSRQ":"2026-09-14","DWJZ":"1.20","LJJZ":"1.30","JZZZL":"1.0","FHFCZ":""}'
          ']},"ErrCode":0}';
      const empty = '{"Data":{"LSJZList":[]},"ErrCode":0}';
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        // 第 2 页起返回空，模拟「翻到没有为止」
        final page = int.parse(req.url.queryParameters['pageIndex'] ?? '1');
        return http.Response.bytes(
            utf8.encode(page == 1 ? page1 : empty), 200);
      }));
      final pts = await src.recentHistory(
          Asset(code: '000001', name: '华夏成长', kind: AssetKind.fund));
      expect(seen.host, 'api.fund.eastmoney.com');
      expect(seen.queryParameters['fundCode'], '000001');
      expect(pts.single.date, '2026-09-14');
      src.dispose();
    });

    test('ETF 也走 lsjz', () async {
      late Uri seen;
      final body = '{"Data":{"LSJZList":['
          '{"FSRQ":"2026-09-14","DWJZ":"4.579","LJJZ":"4.579","JZZZL":"-0.8","FHFCZ":""}'
          ']},"ErrCode":0}';
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(utf8.encode(body), 200);
      }));
      await src.recentHistory(
          Asset(code: '510300', name: '沪深300ETF', kind: AssetKind.etf));
      expect(seen.host, 'api.fund.eastmoney.com');
      src.dispose();
    });

    test('纯股票改走新浪日K，不再请求 lsjz（这就是那个既有缺陷）', () async {
      late Uri seen;
      final body = '[{"day":"2026-09-14","open":"1270.00","close":"1275.16"},'
          '{"day":"2026-09-11","open":"1280.00","close":"1285.13"}]';
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(utf8.encode(body), 200);
      }));
      final pts = await src.recentHistory(
          Asset(code: '600519', name: '贵州茅台', kind: AssetKind.stock, market: 'SH'));

      expect(seen.host, 'quotes.sina.cn', reason: '不该再打基金接口');
      expect(seen.queryParameters['symbol'], 'sh600519');
      expect(pts.length, 2);
      // 返回按日期升序，所以最后一条是 09-14
      expect(pts.map((p) => p.date).toList(), ['2026-09-11', '2026-09-14']);
      expect(pts.last.nav, closeTo(1275.16, 1e-9));
      expect(pts.first.nav, closeTo(1285.13, 1e-9));
      src.dispose();
    });

    test('指数基准同样走新浪日K', () async {
      late Uri seen;
      final src = NavSource(MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(utf8.encode('[]'), 200);
      }));
      await src.recentHistory(
          Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other));
      expect(seen.host, 'quotes.sina.cn');
      expect(seen.queryParameters['symbol'], 'sh000300');
      src.dispose();
    });

    test('sinaDaily 解析：日K 升序、changePct 由开收价得出', () async {
      final body = '[{"day":"2026-09-14","open":"100.00","close":"110.00"},'
          '{"day":"2026-09-11","open":"90.00","close":"100.00"}]';
      final src = NavSource(
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)));
      final pts = await src.sinaDaily(
          Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other));
      expect(pts.map((p) => p.date).toList(),
          ['2026-09-11', '2026-09-14'], reason: '必须按日期升序');
      expect(pts.last.changePct, closeTo(10.0, 1e-9));
      // 指数没有累计净值，accNav 用收盘价兜底
      expect(pts.last.accNav, closeTo(110.0, 1e-9));
      src.dispose();
    });

    test('日K 里的坏行被跳过，不影响整体', () async {
      final body = '[{"day":"2026-09-14","open":"100","close":"110"},'
          '{"day":"bad","open":"1","close":"1"},'
          '{"day":"2026-09-13","open":"0","close":"0"},'
          '{"day":"2026-09-12","open":"100","close":"105"}]';
      final src = NavSource(
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)));
      final pts = await src.sinaDaily(
          Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other));
      expect(pts.length, 2, reason: 'day 非法与 close<=0 的行都要跳过');
      expect(pts.map((p) => p.date).toList(), ['2026-09-12', '2026-09-14']);
      src.dispose();
    });
  });

  group('pingzhongdata 净值日期按 UTC+8 折算', () {
    // 东财真实数据：x=1789056000000 → 2026-09-11 的净值 1.7637，
    // x=1789315200000 → 2026-09-14 的净值 1.7548（与 lsjz 接口逐日对得上）
    test('时间戳代表「净值日 00:00（UTC+8）」', () {
      expect(cnDayFromEpochMillis(1789056000000), '2026-09-11');
      expect(cnDayFromEpochMillis(1789315200000), '2026-09-14');
      expect(cnDayFromEpochMillis(1789401600000), '2026-09-15');
    });

    test('为什么必须写死 UTC+8：按设备时区解释会整体差一天', () {
      // 这个时间戳是 09-10 16:00 UTC（= 09-11 00:00 北京）。
      // 在西八区以西的手机上换算成本地时间就落回 09-10 —— 正是旧写法的 bug
      final utc = DateTime.fromMillisecondsSinceEpoch(1789056000000, isUtc: true);
      expect(utc.day, 10, reason: 'UTC 视角看它是 09-10');
      expect(utc.hour, 16);
      // 固定按 UTC+8 才是净值日 09-11
      expect(cnDayFromEpochMillis(1789056000000), '2026-09-11');
    });

    test('北京时间零点附近不跨日', () {
      // 09-11 00:00(+08) 的前一毫秒仍是 09-10
      expect(cnDayFromEpochMillis(1789056000000 - 1), '2026-09-10');
      // 再加一天正好是新的一天
      expect(cnDayFromEpochMillis(1789056000000 + 86400000), '2026-09-12');
    });

    test('解析净值接口的返回：日期不随设备时区漂移', () async {
      const body = 'var Data_netWorthTrend = ['
          '{"x":1789056000000,"y":1.7637,"equityReturn":-3.09,"unitMoney":""},'
          '{"x":1789315200000,"y":1.7548,"equityReturn":-0.5,"unitMoney":""}'
          '];var Data_ACWorthTrend = [[1789315200000,1.7548]];';
      final src = NavSource(
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200)));
      final pts = await src.fullHistory(
          Asset(code: '021362', name: '易方达黄金股指数发起式A', kind: AssetKind.fund));
      expect(pts.map((p) => p.date).toList(), ['2026-09-11', '2026-09-14'],
          reason: '写死 UTC+8：手机时区改成 UTC+0 也不能变成 09-10 / 09-13');
      expect(pts.last.nav, closeTo(1.7548, 1e-9));
      src.dispose();
    });
  });
}
