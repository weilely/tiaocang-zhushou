import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_catalog.dart';

/// 指数目录：解析 / 本地搜索 / 分类 / 排序 / 缓存
///
/// 响应形状照 **2026-09-29 实测**（`query-index-item`，pageSize=1000 分页拉全 3001 条）。
void main() {
  /// 一条真实行（沪深300，字段原样）
  const row300 = '{"indexCompliance":"IOSCO","ifTracked":"是",'
      '"indexSeries":"中证系列指数","indexSeriesEn":"CSI Indices","key":"000300",'
      '"indexCode":"000300","indexName":"沪深300","indexNameEn":"CSI 300",'
      '"consNumber":"300","latestClose":"4340.76","monthlyReturn":"-5.82",'
      '"indexType":null,"assetsClassify":"股票","assetsClassifyEn":"Equity",'
      '"hotSpot":"","region":"境内","currency":"人民币","ifCustomized":"否",'
      '"indexClassify":"规模","ifWeightCapped":"否","publishDate":"2005-04-08",'
      '"ifProtect":null,"ifTopDing":17}';

  /// 债券指数：没有成分数/月度收益、分类是 `-`
  const rowBond = '{"ifTracked":"否","indexSeries":"上证系列指数","indexCode":"000001",'
      '"indexName":"上证指数","consNumber":"-","latestClose":"3823.62",'
      '"monthlyReturn":"-2.10","assetsClassify":"股票","region":"境内",'
      '"currency":"人民币","indexClassify":"-","publishDate":"1991-07-15"}';

  const rowTheme = '{"ifTracked":"是","indexSeries":"中证系列指数","indexCode":"930740",'
      '"indexName":"300红利LV","consNumber":"50","latestClose":"8123.00",'
      '"monthlyReturn":null,"assetsClassify":"股票","region":"沪深港",'
      '"currency":"人民币","indexClassify":"策略","publishDate":"2013-12-31"}';

  const rowHk = '{"ifTracked":"是","indexSeries":"中华交易系列指数","indexCode":"SHHKSI",'
      '"indexName":"中华港股通精选100","consNumber":"100","latestClose":"5000.00",'
      '"monthlyReturn":"1.20","assetsClassify":"股票","region":"香港",'
      '"currency":"港元","indexClassify":"规模","publishDate":"2016-01-01"}';

  String body(List<String> rows, [int total = 3001]) =>
      '{"data":[${rows.join(',')}],"total":$total,"size":1,"code":"200","success":true}';

  IndexCatalog catalog() {
    final (items, _) = parseIndexCatalogResponse(
        body([row300, rowBond, rowTheme, rowHk]));
    return IndexCatalog(items, DateTime(2026, 9, 29));
  }

  group('解析', () {
    test('实测响应：字段与单位都对', () {
      final (items, total) = parseIndexCatalogResponse(body([row300]));
      expect(total, 3001);
      expect(items, hasLength(1));
      final it = items.single;
      expect(it.code, '000300');
      expect(it.name, '沪深300');
      expect(it.nameEn, 'CSI 300');
      expect(it.series, '中证系列指数');
      expect(it.assetClass, '股票');
      expect(it.classify, '规模');
      expect(it.region, '境内');
      expect(it.currency, '人民币');
      expect(it.consNumber, 300); // 字符串 "300" → int
      expect(it.latestClose, 4340.76);
      expect(it.monthlyReturn, -5.82);
      expect(it.publishDate, '2005-04-08');
      expect(it.tracked, isTrue);
    });

    test('官网的 "-" 当成"没有"，不当成分类值', () {
      final (items, _) = parseIndexCatalogResponse(body([rowBond]));
      expect(items.single.classify, '');
      expect(items.single.consNumber, isNull);
    });

    test('缺代码/缺名字的行直接丢掉', () {
      final (items, _) = parseIndexCatalogResponse(
          '{"data":[{"indexName":"没代码"},{"indexCode":"1"},$row300],"total":3}');
      expect(items, hasLength(1)); // 只剩沪深300
      expect(items.single.code, '000300');
    });

    test('坏 JSON / data 为 null：空表不抛', () {
      expect(parseIndexCatalogResponse('not json').$1, isEmpty);
      expect(parseIndexCatalogResponse('{"data":null,"total":null}').$2, 0);
      expect(parseIndexCatalogResponse('{"data":null,"total":null}').$1, isEmpty);
    });

    test('total 缺失时退回条目数（不要让分页算成 0 页）', () {
      final (items, total) = parseIndexCatalogResponse(
          '{"data":[$row300]}');
      expect(items, hasLength(1));
      expect(total, 1);
    });
  });

  group('本地搜索', () {
    test('代码 / 中文名 / 英文名都能搜到', () {
      final c = catalog();
      expect(c.query(keyword: '000300').single.name, '沪深300');
      expect(c.query(keyword: '红利').single.code, '930740');
      expect(c.query(keyword: 'csi 300').single.code, '000300');
      expect(c.query(keyword: '  沪深  ').single.code, '000300');
    });

    test('空格分词是"全命中"：300 红利 能搜到 300红利LV', () {
      final c = catalog();
      expect(c.query(keyword: '300 红利').map((e) => e.code), ['930740']);
      expect(c.query(keyword: '红利 银行'), isEmpty); // 少一个词就不算命中
    });

    test('关键词只搜代码/中英文名，**不搜系列**（否则搜"中证"会命中几千条）', () {
      final c = catalog();
      expect(c.query(keyword: '中证系列'), isEmpty);
      expect(c.query(series: {'中证系列指数'}).length, 2); // 系列走筛选
    });

    test('搜不到就是空表（页面自己决定怎么显示）', () {
      final c = catalog();
      expect(c.query(keyword: '不存在的东西'), isEmpty);
      expect(c.query(keyword: '').length, 4); // 空关键词 = 全部
    });
  });

  group('分类筛选', () {
    test('按系列 / 资产类别 / 分类 / 地区 过滤', () {
      final c = catalog();
      expect(c.query(series: {'上证系列指数'}).map((e) => e.code), ['000001']);
      expect(c.query(classifies: {'策略'}).map((e) => e.code), ['930740']);
      expect(c.query(regions: {'香港'}).map((e) => e.code), ['SHHKSI']);
      expect(c.query(assetClasses: {'股票'}).length, 4);
      expect(c.query(assetClasses: {'固定收益'}), isEmpty);
    });

    test('只看被基金跟踪的', () {
      final c = catalog();
      expect(c.query(trackedOnly: true).map((e) => e.code),
          ['000300', '930740', 'SHHKSI']);
    });

    test('分类清单按条数从多到少', () {
      final c = catalog();
      expect(c.series.first, '中证系列指数'); // 2 条最多
      expect(c.classifies, contains('规模'));
      expect(c.classifies, isNot(contains(''))); // "-" 不进清单
    });
  });

  group('排序', () {
    test('月度收益：正序 / 倒序', () {
      final c = catalog();
      expect(c.query(sort: IndexSortField.monthlyReturn).map((e) => e.code),
          ['000300', '000001', 'SHHKSI', '930740']); // -5.82 < -2.10 < 1.20 < 缺值
      expect(
          c.query(sort: IndexSortField.monthlyReturn, desc: true)
              .map((e) => e.code),
          ['SHHKSI', '000001', '000300', '930740']);
    });

    test('缺值的永远沉底（倒序也不许冒到最前面充大）', () {
      final c = catalog();
      expect(c.query(sort: IndexSortField.monthlyReturn, desc: true).last.code,
          '930740');
      expect(
          c.query(sort: IndexSortField.consNumber, desc: true).last.code,
          '000001'); // 成分数 "-" 的那条
    });

    test('代码 / 成分数 / 发布日期排序', () {
      final c = catalog();
      expect(c.query(sort: IndexSortField.code).first.code, '000001');
      expect(c.query(sort: IndexSortField.consNumber).first.code, '930740');
      expect(c.query(sort: IndexSortField.publishDate).first.code, '000001');
    });

    test('limit 截断（列表按需渲染用）', () {
      final c = catalog();
      expect(c.query(limit: 2), hasLength(2));
      expect(c.query(limit: 0), hasLength(4)); // 0 = 不限
    });
  });

  group('缓存', () {
    test('写进去再读回来，条数与字段一致', () async {
      final dir = Directory.systemTemp.createTempSync('idx_cat');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = IndexCatalogSource(cacheDir: () async => dir);
      await src.saveCache(catalog());
      final got = await src.loadCache();
      expect(got, isNotNull);
      expect(got!.items, hasLength(4));
      final it = got.items.firstWhere((e) => e.code == '000300');
      expect(it.name, '沪深300');
      expect(it.consNumber, 300);
      expect(it.monthlyReturn, -5.82);
      expect(it.tracked, isTrue);
    });

    test('过了 7 天：allowStale=false 就不算新鲜（但旧的还能读）', () async {
      final dir = Directory.systemTemp.createTempSync('idx_cat_old');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = IndexCatalogSource(cacheDir: () async => dir);
      final old = IndexCatalog(
          catalog().items, DateTime.now().subtract(const Duration(days: 8)));
      await src.saveCache(old);
      expect(await src.loadCache(allowStale: false), isNull);
      expect(await src.loadCache(), isNotNull);
    });

    test('没有缓存 / 缓存坏了：返回 null 不抛', () async {
      final dir = Directory.systemTemp.createTempSync('idx_cat_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = IndexCatalogSource(cacheDir: () async => dir);
      expect(await src.loadCache(), isNull);
      File('${dir.path}${Platform.pathSeparator}index_catalog.json')
          .writeAsStringSync('{{{ 坏文件');
      expect(await src.loadCache(), isNull);
    });
  });
}
