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

  group('指数快照解析', () {
    test('指数域不接受逗号，逐个 thscode 各发一次请求', () async {
      final seen = <String>[];
      final api = HithinkApi(MockClient((req) async {
        seen.add(req.url.queryParameters['thscodes'] ?? '');
        expect(req.url.path, '/api/a-share-index/prices/snapshot');
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'item': [
                {
                  'thscode': req.url.queryParameters['thscodes'],
                  'last_price': 3388.06,
                  'price_change': 12.21,
                  'price_change_ratio_pct': 0.3617,
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
      expect(seen, ['000001.SH', '399001.SZ']);
      expect(got['000001.SH']!['price'], 3388.06);
      expect(got['399001.SZ']!['changePct'], closeTo(0.3617, 1e-9));
    });

    test('认不出市场的代码（黄金）被跳过，不为它发请求', () async {
      var calls = 0;
      final api = HithinkApi(MockClient((req) async {
        calls++;
        return http.Response(jsonEncode({'code': 0, 'data': {'item': []}}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));

      await api.indexSnapshots(['em:118.AU9999', 'sh000001'], 'k');
      expect(calls, 1, reason: '只有 sh000001 该发请求');
    });

    test('单只失败不影响整批', () async {
      final api = HithinkApi(MockClient((req) async {
        final t = req.url.queryParameters['thscodes'];
        if (t == '000001.SH') {
          return http.Response(
              jsonEncode({'code': 3001, 'message': 'not found', 'data': null}), 200,
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
                  'prev_price': 3375.85,
                  'price_change_ratio_pct': 0.36,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final got = await api.indexSnapshots(['sh000001', 'sz399001'], 'k');
      expect(got.containsKey('000001.SH'), isFalse);
      expect(got['399001.SZ']!['price'], 3388.06);
    });
  });
}
