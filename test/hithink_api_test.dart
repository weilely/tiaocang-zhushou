import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:invest_tracker/data/hithink_api.dart';

/// 同花顺行情「第三路」备用源的契约
///
/// 全部用 MockClient 打桩，**不联网**：这一路只在东财/新浪都失败时才接管，
/// 本身错了不会让测试变红，所以映射与解析必须在这里钉死。
void main() {
  group('thscodeFor：带前缀代码 → 同花顺 thscode', () {
    test('sh/sz/bj 前缀各自映射到 .SH/.SZ/.BJ', () {
      expect(HithinkApi.thscodeFor('sh600519'), '600519.SH');
      expect(HithinkApi.thscodeFor('sz000001'), '000001.SZ');
      expect(HithinkApi.thscodeFor('bj899050'), '899050.BJ');
      expect(HithinkApi.thscodeFor('SH600519'), '600519.SH');
    });

    test('裸 6 位复用 MarketService 的市场判断（跟东财那一路同口径）', () {
      expect(HithinkApi.thscodeFor('510300'), '510300.SH');
      expect(HithinkApi.thscodeFor('600519'), '600519.SH');
      // 920xxx / 8xxxxx 是北交所——不能只看首位是 9 就当沪市
      expect(HithinkApi.thscodeFor('920001'), '920001.BJ');
      expect(HithinkApi.thscodeFor('830799'), '830799.BJ');
      expect(HithinkApi.thscodeFor('000001'), '000001.SZ');
      expect(HithinkApi.thscodeFor('399006'), '399006.SZ');
      // **已知缺口（继承自 MarketService.isBeijingCode，只认 920/8）**：
      // 43xxxx 现实中也是北交所，但本项目所有通道都按深市处理它。
      // 这里刻意保持一致 —— 同花顺这一路若判成 .BJ，会和东财那一路
      // 对同一个代码给出不同市场，比"少一个备用源"更糟。
      // 真实使用中池子里的代码都带 sh/sz/bj 前缀（normalizeIndexCode 补的），
      // 走不到这个分支；万一走到了，会让同花顺报「标的不存在」而被跳过，
      // 不会因此显示一个错的价格。
      expect(HithinkApi.thscodeFor('430047'), '430047.SZ');
    });

    test('已经是 thscode 的原样返回（大写）', () {
      expect(HithinkApi.thscodeFor('600519.SH'), '600519.SH');
      expect(HithinkApi.thscodeFor('000001.sz'), '000001.SZ');
    });

    test('认不出来的返回 null —— 宁可放弃这一路，也不猜交易所后缀', () {
      // 上金所黄金 / 期货：`em:118.AU9999` 不属于沪深两市，同花顺也不覆盖
      expect(HithinkApi.thscodeFor('em:118.AU9999'), isNull);
      expect(HithinkApi.thscodeFor('118.AU9999'), isNull);
      expect(HithinkApi.thscodeFor('hkHSI'), isNull);
      expect(HithinkApi.thscodeFor(''), isNull);
      expect(HithinkApi.thscodeFor('12345'), isNull);
      expect(HithinkApi.thscodeFor('abcdef'), isNull);
    });
  });

  group('未配置 Key 时完全不发请求', () {
    test('空 Key：aShareSnapshots 直接返回空，且一次请求都没打', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      }));

      expect(await api.aShareSnapshots(['600519'], ''), isEmpty);
      expect(await api.indexSnapshots(['sh600519'], '   '), isEmpty);
      expect(calls, 0, reason: '没 Key 就不该产生任何网络请求');
    });
  });

  group('A 股/ETF 快照解析', () {
    test('按完整 thscode 作键，价格/涨跌幅/昨收都取对', () async {
      final api = HithinkApi(MockClient((req) async {
        expect(req.headers['X-api-key'], 'k');
        expect(req.url.path, '/api/a-share/prices/snapshot');
        // 逗号批量，一次取整批
        expect(req.url.queryParameters['thscodes'], '600519.SH,000001.SZ');
        return http.Response(
          jsonEncode({
            'code': 0,
            'message': 'success',
            'data': {
              'timestamp': 1784275991000,
              'total': 2,
              'item': [
                {
                  'thscode': '600519.SH',
                  'ticker': '600519',
                  'last_price': 1277.8,
                  'price_change': 21.8,
                  'price_change_ratio_pct': 1.735669,
                  'prev_price': 1256,
                },
                {
                  'thscode': '000001.SZ',
                  'ticker': '000001',
                  'last_price': 11.34,
                  'price_change': -0.06,
                  'price_change_ratio_pct': -0.526,
                  'prev_price': 11.4,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.aShareSnapshots(['sh600519', 'sz000001'], 'k');
      expect(got.keys, containsAll(['600519.SH', '000001.SZ']));
      // 键是完整 thscode：`000001.SH`（上证指数）与 `000001.SZ`（平安银行）
      // 不能用 6 位码混在一起
      expect(got['600519.SH']!['price'], 1277.8);
      expect(got['600519.SH']!['prevPrice'], 1256);
      expect(got['600519.SH']!['changePct'], closeTo(1.735669, 1e-9));
      expect(got['000001.SZ']!['price'], 11.34);
    });

    test('价格缺失（0）的记录被丢掉，不产生 0 元行情', () async {
      final api = HithinkApi(MockClient((req) async => http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'item': [
                  {'thscode': '600519.SH', 'last_price': 0, 'prev_price': 1256},
                  {'thscode': '000001.SZ', 'last_price': 11.34, 'prev_price': 11.4},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )));

      final got = await api.aShareSnapshots(['sh600519', 'sz000001'], 'k');
      expect(got.containsKey('600519.SH'), isFalse);
      expect(got.containsKey('000001.SZ'), isTrue);
    });

    test('业务错误（code != 0）吞掉返回空 —— 不能抛出去打断整轮刷新', () async {
      final api = HithinkApi(MockClient((req) async => http.Response(
            jsonEncode({'code': 2003, 'message': 'Invalid API key', 'data': null}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )));

      expect(await api.aShareSnapshots(['600519'], 'bad'), isEmpty);
    });

    test('HTTP 500 也吞掉返回空', () async {
      final api = HithinkApi(MockClient((req) async => http.Response('oops', 500)));
      expect(await api.aShareSnapshots(['600519'], 'k'), isEmpty);
    });
  });

  group('基础数据代码表（meta/tickers/list）', () {
    test('不满一页就停：一次请求拿完', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        seen.add('${req.url.queryParameters['asset_type']}'
            '|${req.url.queryParameters['offset']}'
            '|${req.url.queryParameters['limit']}');
        expect(req.url.path, '/api/meta/tickers/list');
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': '600519.SH',
                  'ticker': '600519',
                  'name': '贵州茅台',
                  'exchange': 'SH',
                  'asset_type': 'a-share',
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.tickersList('a-share', 'k', limit: 1000);
      expect(seen, ['a-share|0|1000']);
      expect(got.length, 1);
      expect(got.first['ticker'], '600519');
    });

    test('满一页就继续翻，offset 递增，直到不满一页', () async {
      final offsets = <String>[];
      final api = HithinkApi(MockClient((req) async {
        final off = int.parse(req.url.queryParameters['offset'] ?? '0');
        offsets.add('$off');
        // 第一页满（2 条 = limit），第二页只有 1 条 → 停
        final n = off == 0 ? 2 : 1;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                for (var i = 0; i < n; i++)
                  {
                    'thscode': '${off + i}.SH',
                    'ticker': '${off + i}',
                    'name': '标的${off + i}',
                    'exchange': 'SH',
                    'asset_type': 'a-share',
                  },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.tickersList('a-share', 'k', limit: 2);
      expect(offsets, ['0', '2']);
      expect(got.length, 3);
    });

    test('业务错误要抛出去（调用方靠它决定回落原来的通道）', () async {
      final api = HithinkApi(MockClient((req) async => http.Response(
            jsonEncode({'code': 2003, 'message': 'Invalid API key', 'data': null}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )));
      await expectLater(
        api.tickersList('a-share', 'bad'),
        throwsA(isA<HithinkException>()),
      );
    });

    test('未配置 Key：不发请求，返回空', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      }));
      expect(await api.tickersList('a-share', '   '), isEmpty);
      expect(calls, 0);
    });
  });

  group('场内基金快照解析（ETF/LOF 走基金接口，不是 A 股接口）', () {
    test('参数是单数 thscode、一次一个；价格为 0 的记录丢掉', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        seen.add(req.url.queryParameters['thscode'] ?? '');
        expect(req.url.path, '/api/fund/market/snapshot');
        expect(req.url.queryParameters.containsKey('thscodes'), isFalse,
            reason: '该接口参数是单数 thscode');
        final t = req.url.queryParameters['thscode'];
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': t,
                  'ticker': (t ?? '').split('.').first,
                  'last_price': 4.608,
                  'prev_price': 4.838,
                  'price_change_ratio_pct': -1.756924,
                  'price_change': -0.085,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.fundSnapshots(['sh510300', 'sz159915'], 'k');
      expect(seen, ['510300.SH', '159915.SZ']);
      expect(got['510300.SH']!['price'], 4.608);
      expect(got['510300.SH']!['prevPrice'], 4.838);
      expect(got['510300.SH']!['changePct'], closeTo(-1.756924, 1e-9));
      expect(got['159915.SZ']!['price'], 4.608);
    });

    test('场外基金（3001 Fund not found）等错误被吞掉，不影响其它标的', () async {
      final api = HithinkApi(MockClient((req) async {
        final t = req.url.queryParameters['thscode'];
        if (t == '020602.SH') {
          return http.Response(
              jsonEncode(
                  {'code': 3001, 'message': 'Fund not found: 020602.SH', 'data': null}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': t,
                  'last_price': 1.744,
                  'prev_price': 1.75,
                  'price_change_ratio_pct': -0.34,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.fundSnapshots(['sh020602', 'sh501029'], 'k');
      expect(got.containsKey('020602.SH'), isFalse);
      expect(got['501029.SH']!['price'], 1.744);
    });

    test('未配置 Key：不发请求', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      }));
      expect(await api.fundSnapshots(['sh510300'], ''), isEmpty);
      expect(calls, 0);
    });
  });

  group('指数快照解析', () {
    test('批量一个请求拿全部（文档写"不接受逗号"，实测可用）', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        seen.add(req.url.queryParameters['thscodes'] ?? '');
        expect(req.url.path, '/api/a-share-index/prices/snapshot');
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                for (final t in (req.url.queryParameters['thscodes'] ?? '').split(','))
                  {
                    'thscode': t,
                    'last_price': t == '000001.SH' ? 3388.06 : 13730.02,
                    'price_change': 12.21,
                    'price_change_ratio_pct': t == '000001.SH' ? 0.3617 : 0.9,
                    'prev_price': 3375.85,
                  },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.indexSnapshots(['sh000001', 'sz399001'], 'k');
      // 一次请求（逗号批量）而不是两只各一次：跑马灯指标多时省下的就是真金白银
      expect(seen, ['000001.SH,399001.SZ']);
      expect(got['000001.SH']!['price'], 3388.06);
      expect(got['399001.SZ']!['price'], 13730.02);
    });

    test('认不出市场的代码（黄金）被跳过，不为它发请求', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response(jsonEncode({'code': 0, 'data': {'item': []}}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));

      await api.indexSnapshots(['em:118.AU9999', 'sh000001'], 'k');
      expect(calls, 1, reason: '只有 sh000001 该发请求，黄金不覆盖');
    });

    test('批量一条都没回来时退回逐个取（防入参语法变化让整条失效）', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        final t = req.url.queryParameters['thscodes'] ?? '';
        seen.add(t);
        // 多代码的批量请求「被拒」（返回空），单代码请求正常
        final ids = t.split(',');
        if (ids.length > 1) {
          return http.Response(jsonEncode({'code': 0, 'data': {'item': []}}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': t,
                  'last_price': 3388.06,
                  'price_change_ratio_pct': 0.36,
                  'prev_price': 3375.85,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.indexSnapshots(['sh000001', 'sz399001'], 'k');
      expect(seen, ['000001.SH,399001.SZ', '000001.SH', '399001.SZ']);
      expect(got['000001.SH']!['price'], 3388.06);
      expect(got['399001.SZ']!['price'], 3388.06);
    });

    test('只回来一部分时不逐个重试（品种不覆盖是常态，别白打请求）', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        final t = req.url.queryParameters['thscodes'] ?? '';
        seen.add(t);
        // 批量只回 000001.SH 一条（另一只指数同花顺没有）
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': '000001.SH',
                  'last_price': 3388.06,
                  'price_change_ratio_pct': 0.36,
                  'prev_price': 3375.85,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.indexSnapshots(['sh000001', 'sz399888'], 'k');
      expect(seen, ['000001.SH,399888.SZ'], reason: '有结果就不再逐个重试');
      expect(got.containsKey('000001.SH'), isTrue);
      expect(got.containsKey('399888.SZ'), isFalse);
    });
  });

  group('基金详情 thscode：场外基金是 .OF，不按号段猜', () {
    test('场外基金加 .OF（021362 按股票规则会判成 .SZ，同花顺查不到）', () {
      expect(HithinkApi.fundThscodeFor('021362', otc: true), '021362.OF');
      expect(HithinkApi.fundThscodeFor('sh021362', otc: true), '021362.OF');
      expect(HithinkApi.fundThscodeFor(' 021362 ', otc: true), '021362.OF');
    });

    test('场内 ETF/LOF 仍走市场后缀', () {
      expect(HithinkApi.fundThscodeFor('510300', otc: false), '510300.SH');
      expect(HithinkApi.fundThscodeFor('sz159915', otc: false), '159915.SZ');
      expect(HithinkApi.fundThscodeFor('501029', otc: false), '501029.SH');
    });

    test('已经是 thscode 的原样返回（.OF 也认，大写）', () {
      expect(HithinkApi.fundThscodeFor('021362.of', otc: true), '021362.OF');
      expect(HithinkApi.fundThscodeFor('600519.SH', otc: false), '600519.SH');
    });

    test('认不出来的返回 null —— 宁可放弃，也不猜一个后缀', () {
      expect(HithinkApi.fundThscodeFor('em:118.AU9999', otc: false), isNull);
      expect(HithinkApi.fundThscodeFor('', otc: true), isNull);
      expect(HithinkApi.fundThscodeFor('1234567', otc: true), isNull);
      expect(HithinkApi.fundThscodeFor('abcdef', otc: true), isNull);
    });
  });

  group('基金详情接口 fundDetail（按需拉取，失败要抛）', () {
    test('GET + X-api-key + thscode 查询参数，返回整个信封', () async {
      final api = HithinkApi(MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/fund/profile/detail');
        expect(req.url.queryParameters['thscode'], '021362.OF');
        expect(req.headers['X-api-key'], 'k');
        return http.Response(
          jsonEncode({
            'code': 0,
            'message': 'success',
            'data': {
              'item': [
                {'ticker': '021362'}
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got =
          await api.fundDetail('/api/fund/profile/detail', '021362.OF', 'k');
      expect(got['code'], 0);
      final data = got['data'] as Map;
      expect(data['item'], isA<List>());
    });

    test('业务错误（code != 0）必须抛 —— 页面靠它说清"为什么没有数据"', () async {
      final api = HithinkApi(MockClient((req) async => http.Response(
            jsonEncode(
                {'code': 2003, 'message': 'Missing X-api-key', 'data': null}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )));

      await expectLater(
        api.fundDetail('/api/fund/profile/detail', '021362.OF', 'bad'),
        throwsA(isA<HithinkException>()),
      );
    });

    test('未配置 Key：直接抛，一次请求都不发', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      }));

      await expectLater(
        api.fundDetail('/api/fund/profile/detail', '021362.OF', '   '),
        throwsA(isA<HithinkException>()),
      );
      expect(calls, 0);
    });
  });
}
