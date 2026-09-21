import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:invest_tracker/data/market_api.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/securities_repo.dart';
import 'package:invest_tracker/data/securities_source.dart';
import 'package:invest_tracker/logic/pinyin_util.dart';

SecuritiesSource _sourceReturning(String body, {int status = 200}) {
  final client = MockClient(
    (_) async => http.Response.bytes(utf8.encode(body), status),
  );
  return SecuritiesSource(client);
}

void main() {
  // ---------------- 拼音首拼 ----------------

  group('拼音首拼', () {
    test('常见股票名', () {
      expect(pinyinInitials('贵州茅台'), 'GZMT');
      expect(pinyinInitials('平安银行'), 'PAYH');
      expect(pinyinInitials('宁德时代'), 'NDSD');
      expect(pinyinInitials('安徽凤凰'), 'AHFH');
    });

    test('名称里的空格会被忽略', () {
      expect(pinyinInitials('新 和 成'), 'XHC');
    });

    test('名称里的拉丁字母原样保留', () {
      expect(pinyinInitials('TCL科技'), 'TCLKJ');
    });

    test('含数字与 ETF 的基金名', () {
      final py = pinyinInitials('沪深300ETF华泰柏瑞');
      expect(py, contains('HS300ETF'));
      expect(py, endsWith('HTBR'));
    });

    test('全角字母归一化成半角', () {
      expect(pinyinInitials('鲁 泰Ａ'), 'LTA');
    });

    test('全拼', () {
      expect(fullPinyinOf('贵州茅台'), 'guizhoumaotai');
    });

    test('空串不炸', () {
      expect(pinyinInitials(''), '');
      expect(fullPinyinOf(''), '');
    });
  });

  // ---------------- 板块与市场 ----------------

  group('股票板块（上证/深证/创业/科创/北证）', () {
    test('五个板块的代码段逐段覆盖', () {
      expect(boardOf('600519'), '上证');
      expect(boardOf('601398'), '上证');
      expect(boardOf('603000'), '上证');
      expect(boardOf('605001'), '上证');

      expect(boardOf('000001'), '深证');
      expect(boardOf('001201'), '深证');
      expect(boardOf('002001'), '深证');
      expect(boardOf('003000'), '深证');

      expect(boardOf('300001'), '创业');
      expect(boardOf('301000'), '创业');
      expect(boardOf('302132'), '创业');

      expect(boardOf('688001'), '科创');
      expect(boardOf('920000'), '北证');
    });

    test('未预料的代码段有兜底，不会丢成空串', () {
      expect(boardOf('900001'), '上证'); // 沪 B
      expect(boardOf('200001'), '深证'); // 深 B
      expect(boardOf('830799'), '北证'); // 北交所老代码
      expect(boardOf('123456'), isNotEmpty);
    });

    test('市场推断（含北交所）', () {
      expect(MarketService.marketFor('600519'), 'SH');
      expect(MarketService.marketFor('510300'), 'SH');
      expect(MarketService.marketFor('000001'), 'SZ');
      expect(MarketService.marketFor('300750'), 'SZ');
      expect(MarketService.marketFor('920000'), 'BJ');
      expect(MarketService.marketFor('830799'), 'BJ');
    });

    test('secid 前缀与北交所翻前缀兜底', () {
      expect(
        MarketService.secidFor(
            Asset(code: '600519', name: '', kind: AssetKind.stock)),
        '1.600519',
      );
      expect(
        MarketService.secidFor(
            Asset(code: '000001', name: '', kind: AssetKind.stock)),
        '0.000001',
      );
      expect(
        MarketService.secidFor(
            Asset(code: '920000', name: '', kind: AssetKind.stock, market: 'BJ')),
        '0.920000',
      );
      expect(MarketService.flipSecid('0.920000'), '1.920000');
      expect(MarketService.flipSecid('1.600519'), '0.600519');
      expect(MarketService.isBeijingCode('920000'), isTrue);
      expect(MarketService.isBeijingCode('830799'), isTrue);
      expect(MarketService.isBeijingCode('600519'), isFalse);
    });
  });

  // ---------------- 基金列表解析 ----------------

  group('基金列表解析', () {
    const fundBody = 'var r = ['
        '["000001","HXCZHH","华夏成长混合","混合型-灵活","HUAXIACHENGZHANGHUNHE"],'
        '["510300","HS300ETFHTBR","沪深300ETF华泰柏瑞","指数型-股票","HUASHEN300ETFHUATAIBORUI"],'
        '["159915","CYBETFYFD","创业板ETF易方达","指数型-股票","CHUANGYEBANETFYIFANGDA"],'
        '["110022","YFDXFHYGP","易方达消费行业股票","股票型","YIFANGDAXIAOFEIHANGYEGUPIAO"],'
        '["000003","","中海可转债债券A","债券型-混合二级","ZHONGHAIKEZHUANZHAIZHAIQUANA"],'
        '["999999","KDMM","测试无类型基金","","CESHIWULEIXINGJIJIN"]'
        '];';

    test('字段提取、场内/场外归类、类型拆分', () async {
      final src = _sourceReturning(fundBody);
      final rows = await src.fetchFundList();
      expect(rows.length, 6);

      // 场外基金
      final fund = rows[0];
      expect(fund.code, '000001');
      expect(fund.kind, 'fund');
      expect(fund.name, '华夏成长混合');
      expect(fund.pinyin, 'HXCZHH');
      expect(fund.secType, '混合型-灵活');
      expect(fund.secClass, '混合型');
      expect(fund.secSub, '灵活');
      expect(fund.market, ''); // 场外没有市场
      expect(fund.source, 'fund_list');

      // 沪市 ETF
      final shEtf = rows[1];
      expect(shEtf.kind, 'etf');
      expect(shEtf.market, 'SH');
      expect(shEtf.secClass, '指数型');
      expect(shEtf.secSub, '股票');
      expect(shEtf.pinyin, 'HS300ETFHTBR');

      // 深市 ETF
      expect(rows[2].kind, 'etf');
      expect(rows[2].market, 'SZ');

      // 只有一级、没有二级的类型
      expect(rows[3].secType, '股票型');
      expect(rows[3].secClass, '股票型');
      expect(rows[3].secSub, '');

      src.dispose();
    });

    test('首拼缺失时本地补算', () async {
      final src = _sourceReturning(fundBody);
      final rows = await src.fetchFundList();
      final row = rows.firstWhere((r) => r.code == '000003');
      expect(row.pinyin, isNotEmpty);
      expect(row.pinyin, 'ZHKZZZQA');
      src.dispose();
    });

    test('类型为空 → 未分类，不丢记录', () async {
      final src = _sourceReturning(fundBody);
      final rows = await src.fetchFundList();
      final row = rows.firstWhere((r) => r.code == '999999');
      expect(row.secType, '未分类');
      expect(row.secClass, '未分类');
      expect(row.secSub, '');
      src.dispose();
    });

    test('HTTP 非 200 抛明确异常', () async {
      final src = _sourceReturning('', status: 502);
      await expectLater(
        src.fetchFundList(),
        throwsA(isA<SecuritiesUpdateException>()),
      );
      src.dispose();
    });

    test('格式变更导致解析为空时抛异常，而不是静默成功', () async {
      final src = _sourceReturning('{"unexpected":"shape"}');
      await expectLater(
        src.fetchFundList(),
        throwsA(isA<SecuritiesUpdateException>()),
      );
      src.dispose();
    });
  });

  // ---------------- 股票分页解析 ----------------

  group('股票分页解析', () {
    const stockBody = '['
        '{"symbol":"bj920000","code":"920000","name":"安徽凤凰"},'
        '{"symbol":"sh600519","code":"600519","name":"贵州茅台"},'
        '{"symbol":"sh688001","code":"688001","name":"华兴源创"},'
        '{"symbol":"sz300750","code":"300750","name":"宁德时代"},'
        '{"symbol":"sz000001","code":"000001","name":"平安银行"}'
        ']';

    test('市场与板块落库正确', () async {
      final src = _sourceReturning(stockBody);
      final res = await src.fetchStockPage(1);
      expect(res.rows.length, 5);

      final bj = res.rows[0];
      expect(bj.market, 'BJ');
      expect(bj.secType, '股票-北证');
      expect(bj.secClass, '股票');
      expect(bj.secSub, '北证');
      expect(bj.pinyin, 'AHFH');
      expect(bj.kind, 'stock');

      expect(res.rows[1].market, 'SH');
      expect(res.rows[1].secType, '股票-上证');
      expect(res.rows[1].pinyin, 'GZMT');

      expect(res.rows[2].secSub, '科创');
      expect(res.rows[2].market, 'SH');
      expect(res.rows[3].secSub, '创业');
      expect(res.rows[3].market, 'SZ');
      expect(res.rows[4].secSub, '深证');

      src.dispose();
    });

    test('空响应返回空页而不是抛错', () async {
      final src = _sourceReturning('');
      final res = await src.fetchStockPage(56);
      expect(res.rows, isEmpty);
      src.dispose();
    });

    test('非法 JSON 抛明确异常', () async {
      final src = _sourceReturning('<!doctype html>');
      await expectLater(
        src.fetchStockPage(1),
        throwsA(isA<SecuritiesUpdateException>()),
      );
      src.dispose();
    });

    test('股票总数解析（带引号也能读）', () async {
      final src = _sourceReturning('"5561"');
      expect(await src.fetchStockTotal(), 5561);
      src.dispose();
    });
  });

  // ---------------- 类型 → 资产大类 ----------------

  group('类型/板块 → 资产大类（再平衡默认值）', () {
    SecurityRow row(String cls, String sub) =>
        SecurityRow(code: 'x', kind: 'fund', name: 'x', secClass: cls, secSub: sub);

    test('基金一级类型映射', () {
      expect(assetCategoryFor(row('债券型', '长债')), '债券');
      expect(assetCategoryFor(row('货币型', '普通货币')), '现金');
      expect(assetCategoryFor(row('QDII', '')), '海外');
      expect(assetCategoryFor(row('指数型', '股票')), '股票');
      expect(assetCategoryFor(row('股票型', '')), '股票');
      expect(assetCategoryFor(row('混合型', '偏股')), '混合');
      expect(assetCategoryFor(row('FOF', '稳健型')), '混合');
      expect(assetCategoryFor(row('Reits', '')), '另类');
      expect(assetCategoryFor(row('商品', '')), '另类');
    });

    test('股票按板块映射', () {
      for (final board in ['上证', '深证', '创业', '科创', '北证']) {
        expect(assetCategoryFor(row('股票', board)), '股票',
            reason: '$board 应映射到股票');
      }
    });

    test('未分类不给默认值', () {
      expect(assetCategoryFor(row('未分类', '')), '');
    });
  });

  // ---------------- 展示 ----------------

  group('候选项展示', () {
    test('副标题含代码 / 类型 / 板块', () {
      const fund = SecurityRow(
        code: '510300',
        kind: 'etf',
        name: '沪深300ETF华泰柏瑞',
        secType: '指数型-股票',
        secClass: '指数型',
        secSub: '股票',
        market: 'SH',
      );
      expect(fund.subtitle, contains('510300'));
      expect(fund.subtitle, contains('ETF/LOF'));
      expect(fund.subtitle, contains('指数型-股票'));

      const stock = SecurityRow(
        code: '600519',
        kind: 'stock',
        name: '贵州茅台',
        secType: '股票-上证',
        secClass: '股票',
        secSub: '上证',
        market: 'SH',
      );
      expect(stock.subtitle, contains('股票'));
      expect(stock.subtitle, contains('上证'));
    });

    test('marketLabel 中文名', () {
      expect(
        const SecurityRow(code: 'x', kind: 'stock', name: 'x', market: 'SH')
            .marketLabel,
        '沪市',
      );
      expect(
        const SecurityRow(code: 'x', kind: 'stock', name: 'x', market: 'BJ')
            .marketLabel,
        '北证',
      );
      expect(
        const SecurityRow(code: 'x', kind: 'fund', name: 'x').marketLabel,
        '',
      );
    });
  });

  // ---------------- 行情兜底 ----------------

  group('行情兜底（交易所接口挂掉时用基金接口）', () {
    const etfBody = '{"Datas":[{"FCODE":"510300","SHORTNAME":"沪深300ETF华泰柏瑞",'
        '"PDATE":"2026-09-11","NAV":"4.5794","NAVCHGRT":"-0.83",'
        '"NEWPRICE":"4.579","CHANGERATIO":"-0.82","HQDATE":"2026-09-11 16:11:36",'
        '"GSZ":null,"GSZZL":null,"GZTIME":null}],"ErrCode":0,"Success":true}';

    test('场内基金从基金接口读到交易所现价 NEWPRICE', () async {
      final client =
          MockClient((_) async => http.Response.bytes(utf8.encode(etfBody), 200));
      final svc = MarketService(client);
      final quotes = await svc.fetchFundNavs(['510300'], kinds: {'510300': AssetKind.etf});
      final q = quotes['510300']!;

      expect(q.price, closeTo(4.579, 1e-9));
      expect(q.changePct, closeTo(-0.82, 1e-9));
      expect(q.priceType, 'price');
      expect(q.infoDate, '2026-09-11');
      expect(q.kind, AssetKind.etf);
      expect(q.tradeDay, DateTime(2026, 9, 11));
      expect(q.prevClose, closeTo(4.579 / (1 - 0.0082), 1e-6));
      svc.dispose();
    });

    test('push2 返回 502 时，ETF 自动退回基金接口', () async {
      final client = MockClient((req) async {
        if (req.url.host.contains('push2')) {
          return http.Response('', 502);
        }
        return http.Response.bytes(utf8.encode(etfBody), 200);
      });
      final svc = MarketService(client);
      final quotes = await svc.fetchAll([
        Asset(code: '510300', name: '', kind: AssetKind.etf, market: 'SH'),
      ]);

      expect(quotes['510300'], isNotNull, reason: '兜底后必须还能拿到行情');
      expect(quotes['510300']!.price, closeTo(4.579, 1e-9));
      svc.dispose();
    });

    test('股票没有基金接口兜底；全都拿不到时明确报错而不是静默', () async {
      final client = MockClient((req) async {
        if (req.url.host.contains('push2')) return http.Response('', 502);
        return http.Response.bytes(utf8.encode(etfBody), 200);
      });
      final svc = MarketService(client);
      await expectLater(
        svc.fetchAll([
          Asset(code: '600519', name: '', kind: AssetKind.stock, market: 'SH'),
        ]),
        throwsA(isA<MarketException>()),
        reason: '一个标的都没拿到时要抛出原因，让界面能提示用户',
      );
      svc.dispose();
    });

    test('混合持仓：ETF 有兜底、股票没有，整体不报错', () async {
      final client = MockClient((req) async {
        if (req.url.host.contains('push2')) return http.Response('', 502);
        return http.Response.bytes(utf8.encode(etfBody), 200);
      });
      final svc = MarketService(client);
      final quotes = await svc.fetchAll([
        Asset(code: '510300', name: '', kind: AssetKind.etf, market: 'SH'),
        Asset(code: '600519', name: '', kind: AssetKind.stock, market: 'SH'),
      ]);
      expect(quotes['510300'], isNotNull, reason: 'ETF 靠兜底拿到行情');
      expect(quotes.containsKey('600519'), isFalse, reason: '股票只能缺行情');
      svc.dispose();
    });

    test('场外基金优先用盘中估值，且日期取估值日期', () async {
      const body = '{"Datas":[{"FCODE":"000001","SHORTNAME":"华夏成长混合",'
          '"PDATE":"2026-09-10","NAV":"1.2500","NAVCHGRT":"-0.5",'
          '"GSZ":"1.2600","GSZZL":"0.8","GZTIME":"2026-09-11 14:30",'
          '"NEWPRICE":null}],"ErrCode":0}';
      final client =
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200));
      final svc = MarketService(client);
      final q = (await svc.fetchFundNavs(['000001']))['000001']!;

      expect(q.price, closeTo(1.26, 1e-9));
      expect(q.priceType, 'est');
      expect(q.infoDate, '2026-09-11');
      svc.dispose();
    });

    test('没有估值也没有现价时退回单位净值', () async {
      const body = '{"Datas":[{"FCODE":"000001","SHORTNAME":"华夏成长混合",'
          '"PDATE":"2026-09-11","NAV":"1.2540","NAVCHGRT":"-0.63",'
          '"GSZ":null,"GSZZL":null,"NEWPRICE":null}],"ErrCode":0}';
      final client =
          MockClient((_) async => http.Response.bytes(utf8.encode(body), 200));
      final svc = MarketService(client);
      final q = (await svc.fetchFundNavs(['000001']))['000001']!;

      expect(q.price, closeTo(1.254, 1e-9));
      expect(q.priceType, 'nav');
      expect(q.infoDate, '2026-09-11');
      expect(q.tradeDay, DateTime(2026, 9, 11));
      svc.dispose();
    });
  });

  // ---------------- 同花顺代码表 → 基础数据行 ----------------

  group('同花顺代码表映射', () {
    Map<String, dynamic> item(String ticker, String name, String assetType,
            {String? exchange}) =>
        {
          'thscode': '$ticker.${exchange ?? 'OF'}',
          'ticker': ticker,
          'name': name,
          'exchange': exchange,
          'asset_type': assetType,
        };

    test('A 股：板块由代码推、市场用接口给的 exchange、拼音本地生成', () {
      final r = SecuritiesSource.rowFromHithink(
          item('600519', '贵州茅台', 'a-share', exchange: 'SH'), 1);
      expect(r, isNotNull);
      expect(r!.code, '600519');
      expect(r.kind, 'stock');
      expect(r.name, '贵州茅台');
      expect(r.market, 'SH');
      expect(r.secType, '股票-上证');
      expect(r.secClass, '股票');
      expect(r.secSub, '上证');
      expect(r.pinyin, 'GZMT');
      expect(r.fullPinyin, 'guizhoumaotai');
      expect(r.source, 'hithink');
      expect(r.updatedAt, 1);
    });

    test('北交所 920xxx 归北证、市场 BJ', () {
      final r = SecuritiesSource.rowFromHithink(
          item('920001', '某北交所股', 'a-share', exchange: 'BJ'), 1)!;
      expect(r.secSub, '北证');
      expect(r.market, 'BJ');
    });

    test('exchange 缺失时按板块兜市场，不留空', () {
      final r = SecuritiesSource.rowFromHithink(
          item('688111', '科创某某', 'a-share'), 1)!;
      expect(r.market, 'SH'); // 科创 → 沪
      final r2 =
          SecuritiesSource.rowFromHithink(item('300750', '创业某某', 'a-share'), 1)!;
      expect(r2.market, 'SZ');
    });

    test('场外基金：kind=fund、没有市场、类型只能记未分类', () {
      final r = SecuritiesSource.rowFromHithink(
          item('000001', '华夏成长', 'fund-otc'), 1)!;
      expect(r.kind, 'fund');
      expect(r.market, '');
      expect(r.secClass, '未分类');
      expect(r.secType, '未分类');
      expect(r.pinyin, 'HXCZ');
    });

    test('ETF / LOF 都算 etf，市场取 exchange', () {
      final etf = SecuritiesSource.rowFromHithink(
          item('510300', '沪深300ETF', 'fund-etf', exchange: 'SH'), 1)!;
      expect(etf.kind, 'etf');
      expect(etf.market, 'SH');

      final lof = SecuritiesSource.rowFromHithink(
          item('501029', '红利基金', 'fund-lof', exchange: 'SH'), 1)!;
      expect(lof.kind, 'etf');
      expect(lof.market, 'SH');
    });

    test('ETF 的 exchange 缺失时按代码前缀兜（沪 5 / 深 1）', () {
      final sh = SecuritiesSource.rowFromHithink(
          item('510300', '沪深300ETF', 'fund-etf'), 1)!;
      expect(sh.market, 'SH');
      final sz = SecuritiesSource.rowFromHithink(
          item('159915', '创业板ETF', 'fund-etf'), 1)!;
      expect(sz.market, 'SZ');
    });

    test('指数/期货/期权不进基础数据（与现有口径一致）', () {
      expect(
          SecuritiesSource.rowFromHithink(item('000001', '上证指数', 'a-share-index'), 1),
          isNull);
      expect(SecuritiesSource.rowFromHithink(item('IF2609', '沪深300期指', 'futures'), 1),
          isNull);
    });

    test('缺代码或缺名称的条目跳过，不产生空行', () {
      expect(
          SecuritiesSource.rowFromHithink(
              item('', '没有代码', 'a-share', exchange: 'SH'), 1),
          isNull);
      expect(
          SecuritiesSource.rowFromHithink(
              item('600000', '', 'a-share', exchange: 'SH'), 1),
          isNull);
    });

    test('批量映射：认不出的丢掉，同一批 updated_at 一致', () {
      final rows = SecuritiesSource.rowsFromHithink([
        item('600519', '贵州茅台', 'a-share', exchange: 'SH'),
        item('000001', '上证指数', 'a-share-index'),
        item('000001', '华夏成长', 'fund-otc'),
      ]);
      expect(rows.length, 2);
      expect(rows.map((e) => e.code), containsAll(['600519', '000001']));
      expect(rows[0].updatedAt, rows[1].updatedAt);
    });
  });
}
