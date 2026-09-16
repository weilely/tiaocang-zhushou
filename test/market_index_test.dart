import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/nav_models.dart';

/// 首页跑马灯指数配置的解析
///
/// 老数据只存代码（`sh000001,sz399001`），新数据允许 `代码|名称`
/// 让「按代码自定义」的指数也有个像样的标题栏名字。
void main() {
  test('只有代码的老数据照样解析', () {
    final e = parseIndexEntries('sh000001,sz399001,sz399006');
    expect(e.map((x) => x.code).toList(), ['sh000001', 'sz399001', 'sz399006']);
    expect(e.every((x) => x.name.isEmpty), isTrue);
  });

  test('代码|名称 形式解析出名字，空格与多余分隔都容忍', () {
    final e = parseIndexEntries(' sh000300 | 沪深300 , hkHSI|恒生指数 ,,');
    expect(e, hasLength(2));
    expect(e.first.code, 'sh000300');
    expect(e.first.name, '沪深300');
    expect(e.last.name, '恒生指数');
  });

  test('同名代码去重、空片段丢弃', () {
    final e = parseIndexEntries('sh000300|沪深300,sh000300|重复, ,');
    expect(e, hasLength(1));
    expect(e.single.raw, 'sh000300|沪深300');
  });

  test('raw 序列化：没名字就只写代码', () {
    expect(const MarketIndexEntry('sh000300').raw, 'sh000300');
    expect(const MarketIndexEntry('sh000300', '沪深300').raw, 'sh000300|沪深300');
  });

  test('展示名：预设名优先，其次自定义名，最后退回代码', () {
    const entries = [
      MarketIndexEntry('sh000300', '我起的名字'),
      MarketIndexEntry('sz399905', '中证500'),
    ];
    // 预设里的（沪深300 在 presets 里叫「沪深300」）→ 用预设名
    expect(indexDisplayName('sh000300', entries), '沪深300');
    // 预设里没有 → 用自定义名
    expect(indexDisplayName('sz399905', entries), '中证500');
    // 都没有 → 退回代码
    expect(indexDisplayName('hkHSI', entries), 'hkHSI');
  });

  // ---------------- 行情指标池 ----------------

  group('代码规范化', () {
    test('6 位代码自动补市场前缀', () {
      expect(normalizeIndexCode('510300'), 'sh510300'); // 沪市 ETF
      expect(normalizeIndexCode('159915'), 'sz159915'); // 深市 ETF
      expect(normalizeIndexCode('600519'), 'sh600519'); // 沪市股票
      expect(normalizeIndexCode('000001'), 'sz000001'); // 平安银行（要上证指数得写 sh000001）
      expect(normalizeIndexCode('300750'), 'sz300750');
      expect(normalizeIndexCode('830799'), 'bj830799');
    });

    test('带前缀的原样保留；港美股不折大小写', () {
      expect(normalizeIndexCode(' sh000300 '), 'sh000300');
      expect(normalizeIndexCode('SH000300'), 'sh000300');
      expect(normalizeIndexCode('hkHSI'), 'hkHSI');
      expect(normalizeIndexCode('gb_AAPL'), 'gb_AAPL');
    });
  });

  group('简称', () {
    test('从全名里截关键字', () {
      expect(defaultIndexShort('沪深300ETF华泰柏瑞'), '沪深300');
      expect(defaultIndexShort('易方达黄金股指数发起式A'), '易方达黄金股');
      expect(defaultIndexShort('中证500ETF（510500）'), '中证500');
      expect(defaultIndexShort(''), '');
    });
  });

  group('池子读写与迁移', () {
    test('JSON 往返', () {
      const list = [
        IndexEntry(code: 'sh000300', name: '沪深300', short: '沪深300', on: true),
        IndexEntry(code: 'sh510300', name: '沪深300ETF华泰柏瑞', short: '300ETF'),
      ];
      final back = parseIndexPool(encodeIndexPool(list));
      expect(back.map((e) => e.code).toList(), ['sh000300', 'sh510300']);
      expect(back.first.on, isTrue);
      expect(back.last.on, isFalse);
      expect(back.last.label, '300ETF');
    });

    test('坏数据不崩、重复代码去重', () {
      expect(parseIndexPool(null), isEmpty);
      expect(parseIndexPool('不是 json'), isEmpty);
      expect(parseIndexPool('{"a":1}'), isEmpty);
      final dup = parseIndexPool(
          '[{"code":"sh000300","name":"A","on":true},{"code":"sh000300","name":"B"}]');
      expect(dup, hasLength(1));
      expect(dup.single.name, 'A');
    });

    test('老数据（只有代码/名称）迁移成"已显示"', () {
      final e = IndexEntry.fromLegacy(const MarketIndexEntry('sh000300', '沪深300'));
      expect(e.on, isTrue);
      expect(e.code, 'sh000300');
      expect(e.short, '沪深300');
      // 没名字的（老数据只有代码）用预设名
      final p = IndexEntry.fromLegacy(const MarketIndexEntry('sz399006'));
      expect(p.short, '创业板指');
      expect(p.on, isTrue);
    });
  });

  group('价格小数位', () {
    test('基金 4 位，指数/股票 2 位', () {
      expect(priceDigitsForKind('fund'), 4);
      expect(priceDigitsForKind('etf'), 4);
      expect(priceDigitsForKind('index'), 2);
      expect(priceDigitsForKind('stock'), 2);
    });

    test('类型随池子往返', () {
      const e = IndexEntry(code: 'sz021362', name: '易方达黄金股', short: '黄金股', kind: 'fund');
      final back = parseIndexPool(encodeIndexPool([e])).single;
      expect(back.kind, 'fund');
      expect(back.copyWith(on: true).kind, 'fund');
    });
  });
}