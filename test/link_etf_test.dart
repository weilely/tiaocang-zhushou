import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/link_etf.dart';

/// 场外基金 → 关联 ETF 的猜测规则
///
/// 用的是用户真实持仓里的两只场外基金：021362（黄金股指数）与 025497（国证价值100
/// ETF 联接），候选来自东财搜索接口的真实返回。
void main() {
  group('fundCoreName', () {
    test('剥掉份额字母与「联接发起式 / 指数 / ETF」这类后缀', () {
      expect(fundCoreName('易方达国证价值100ETF联接发起式A'), '易方达国证价值100');
      expect(fundCoreName('易方达黄金股指数发起式A'), '易方达黄金股');
      expect(fundCoreName('国泰黄金股ETF联接C'), '国泰黄金股');
    });

    test('只剥末尾的后缀：夹在中间的 ETF 不动', () {
      expect(fundCoreName('沪深300ETF华泰柏瑞'), '沪深300ETF华泰柏瑞');
    });

    test('去掉括号里的说明，也去掉「混合 / 股票」这类类型词', () {
      expect(fundCoreName('华夏成长混合（QDII）A'), '华夏成长');
    });
  });

  group('fundLinkKeywords', () {
    test('含主名、去掉公司简称的变体、以及末尾片段 + ETF', () {
      final kw = fundLinkKeywords('易方达国证价值100ETF联接发起式A');
      expect(kw.first, '易方达国证价值100');
      expect(kw, contains('国证价值100')); // 去掉「易方达」之后
      // 「价值ETF易方达」不含「国证价值100」，靠这条把它捞进来
      expect(kw, contains('价值ETF'));
    });

    test('名字里的汉字片段照样能配出关键词', () {
      final kw = fundLinkKeywords('易方达黄金股指数发起式A');
      expect(kw.first, '易方达黄金股');
      expect(kw, contains('黄金股'));
      expect(kw, contains('黄金股ETF'));
    });
  });

  group('isExchangeEtfCode', () {
    test('沪市 5xxxxx、深市 15/16xxxx 算场内', () {
      expect(isExchangeEtfCode('510300'), isTrue);
      expect(isExchangeEtfCode('159263'), isTrue);
      expect(isExchangeEtfCode('161725'), isTrue);
    });

    test('场外基金 0 开头不算', () {
      expect(isExchangeEtfCode('021362'), isFalse);
      expect(isExchangeEtfCode('025497'), isFalse);
      expect(isExchangeEtfCode('51030'), isFalse);
    });
  });

  group('linkEtfScore / pickLinkEtf', () {
    test('同指数时选同一家公司的 ETF（公司名权重更高）', () {
      final best = pickLinkEtf('易方达国证价值100ETF联接发起式A', {
        '159096': '价值ETF华夏',
        '159037': '价值ETF鹏华',
        '159263': '价值ETF易方达',
      });
      expect(best?.code, '159263');
      expect(best?.name, '价值ETF易方达');
    });

    test('公司对不上时比名字重合度：黄金股 > 黄金', () {
      final best = pickLinkEtf('易方达黄金股指数发起式A', {
        '518880': '黄金ETF华安',
        '517400': '黄金股ETF国泰',
        '159562': '黄金股ETF华夏',
      });
      expect(best?.name, contains('黄金股ETF'));
    });

    test('一点不像就返回 null（宁可留空让用户自己选）', () {
      expect(
        pickLinkEtf('易方达黄金股指数发起式A', {'510300': '沪深300ETF华泰柏瑞'}),
        isNull,
      );
      expect(pickLinkEtf('易方达黄金股指数发起式A', const {}), isNull);
    });

    test('场外基金混在候选里会被忽略', () {
      final best = pickLinkEtf('易方达国证价值100ETF联接发起式A', {
        '025497': '易方达国证价值100ETF联接发起式A',
        '025498': '易方达国证价值100ETF联接发起式C',
      });
      expect(best, isNull);
    });
  });

  group('longestCommonSubstring', () {
    test('基本情形', () {
      expect(longestCommonSubstring('易方达黄金股', '黄金股ETF永赢'), 3);
      expect(longestCommonSubstring('abc', 'xyz'), 0);
      expect(longestCommonSubstring('', 'abc'), 0);
    });
  });
}
