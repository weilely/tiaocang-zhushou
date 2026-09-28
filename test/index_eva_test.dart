import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_eva.dart';

/// 指数估值链路的两段解析（形状都是 **2026-09-28 实测响应**剪出来的）
void main() {
  group('东财联想 → 指数候选', () {
    test('只挑"指数"，基金/股票要扔掉', () {
      final list = parseEastmoneySuggest({
        'QuotationCodeTable': {
          'Data': [
            {
              'Code': '024564',
              'Name': '易方达中证红利价值ETF联接A',
              'SecurityTypeName': '基金',
              'QuoteID': '150.024564',
            },
            {
              'Code': '000922',
              'Name': '中证红利',
              'SecurityTypeName': '指数',
              'QuoteID': '1.000922',
            },
            {
              'Code': 'H30269',
              'Name': '红利低波',
              'SecurityTypeName': '指数',
              'QuoteID': '2.H30269',
            },
          ],
        },
      });
      expect(list.length, 2);
      expect(list.map((e) => e.name), ['中证红利', '红利低波']);
      expect(list.first.code, '000922');
    });

    test('符号猜测：沪市 1. 开头先试 SH，中证 H 代码先试 CSI', () {
      const sh = IndexCandidate(quoteId: '1.000922', code: '000922', name: '中证红利');
      expect(sh.symbolGuesses.first, 'SH000922');

      const csi = IndexCandidate(quoteId: '2.H30269', code: 'H30269', name: '红利低波');
      expect(csi.symbolGuesses.first, 'CSIH30269');
      // 每个候选都带兜底，不至于一次猜不中就彻底查不到
      expect(csi.symbolGuesses.length, greaterThan(1));
    });

    test('脏数据不崩：不是 Map、没有 Data、字段缺失', () {
      expect(parseEastmoneySuggest(null), isEmpty);
      expect(parseEastmoneySuggest({'QuotationCodeTable': 'x'}), isEmpty);
      expect(
        parseEastmoneySuggest({
          'QuotationCodeTable': {
            'Data': [
              {'Code': '', 'Name': '空的', 'SecurityTypeName': '指数'},
              {'Code': '000922', 'SecurityTypeName': '指数'}, // 没名字
              'not-a-map',
            ],
          },
        }),
        isEmpty,
      );
    });
  });

  group('蛋卷 → 指数估值', () {
    Map<String, Object?> resp() => {
          'data': {
            'index_code': 'SH000922',
            'name': '中证红利',
            'pe': 8.6082,
            'pb': 0.8485,
            'yeild': 0.0426,
            'roe': 0.0986,
            'pe_percentile': 0.7928,
            'pb_percentile': 0.5032,
            'eva_type': 'high',
            'begin_at': 1466352000000,
            'date': '2026-09-28',
          },
        };

    test('解析实测响应：股息率是小数（0.0426 = 4.26%）', () {
      final v = IndexValuation.fromJson('SH000922', resp())!;
      expect(v.name, '中证红利');
      expect(v.pe, closeTo(8.6082, 1e-4));
      expect(v.pb, closeTo(0.8485, 1e-4));
      expect(v.yeild, closeTo(0.0426, 1e-6));
      expect(v.roe, closeTo(0.0986, 1e-6));
      expect(v.pePercentile, closeTo(0.7928, 1e-4));
      expect(v.evaType, 'high');
      expect(v.date, '2026-09-28');
      expect(v.windowStart, isNotNull);
      expect(v.windowStart!.year, 2016);
    });

    test('没有名字 = 蛋卷不认这个符号 → null（界面据此说"暂无数据源"）', () {
      expect(IndexValuation.fromJson('CSI980080', {'data': {'pe': 1}}), isNull);
      expect(IndexValuation.fromJson('CSI980080', {'data': null}), isNull);
      expect(IndexValuation.fromJson('CSI980080', null), isNull);
    });

    test('字段缺失时留 null，不编 0', () {
      final v = IndexValuation.fromJson('SH000300', {
        'data': {'name': '沪深300', 'pe': 13.1274},
      })!;
      expect(v.pe, closeTo(13.1274, 1e-4));
      expect(v.yeild, isNull);
      expect(v.pb, isNull);
      expect(v.windowStart, isNull);
      expect(v.date, '');
    });
  });

  group('实测收录的种子清单', () {
    test('只放实测收录的（8 个），符号格式与实测一致', () {
      expect(kVerifiedIndexSymbols.length, 8);
      final symbols = kVerifiedIndexSymbols.map((e) => e.symbol).toSet();
      // 这两个是实测逐个验过能出股息率的
      expect(symbols.contains('SH000922'), isTrue); // 中证红利 4.26%
      expect(symbols.contains('CSIH30269'), isTrue); // 红利低波 4.42%
      for (final e in kVerifiedIndexSymbols) {
        expect(e.name.trim(), isNotEmpty);
        expect(e.symbol, matches(RegExp(r'^(SH|SZ|CSI)')));
      }
    });
  });

  group('只有代码时的符号猜测（中证目录里没有东财 QuoteID）', () {
    test('中证系（H/9 开头）先试 CSI', () {
      expect(symbolGuessesForCode('H30269').first, 'CSIH30269');
      expect(symbolGuessesForCode('930740').first, 'CSI930740');
      expect(symbolGuessesForCode('931238').first, 'CSI931238');
    });

    test('沪市 000xxx 先试 SH（蛋卷里 000922 = SH000922，实测过）', () {
      expect(symbolGuessesForCode('000922').first, 'SH000922');
      expect(symbolGuessesForCode('000300').first, 'SH000300');
    });

    test('深市/国证（399/98 开头）先试 SZ', () {
      expect(symbolGuessesForCode('399006').first, 'SZ399006');
      expect(symbolGuessesForCode('980080').first, 'SZ980080');
    });

    test('三个候选都会给全（成不成由返回的 name 判），空代码给空表', () {
      expect(symbolGuessesForCode('000922'),
          ['SH000922', 'CSI000922', 'SZ000922']);
      expect(symbolGuessesForCode('  h30269 '),
          ['CSIH30269', 'SHH30269', 'SZH30269']); // 大小写/空格都容错
      expect(symbolGuessesForCode(''), isEmpty);
    });
  });

  group('两来源的名字比对（只用于挑更可信的猜测）', () {
    test('相等 / 互相包含 / 噪声差异都算同一个指数', () {
      expect(indexNameMatches('中证红利', '中证红利指数'), isTrue); // 去「指数」
      expect(indexNameMatches('中证红利', '中证红利'), isTrue);
      expect(indexNameMatches('黄金股票', 'SSH黄金股票'), isTrue); // 实测会遇到的
      expect(indexNameMatches('沪深300', '沪深 300'), isTrue);
    });

    test('不同指数不算（宁可显示两个名字，也不能张冠李戴）', () {
      expect(indexNameMatches('中证红利', '沪深300'), isFalse);
      expect(indexNameMatches('中证红利', ''), isFalse);
      expect(indexNameMatches('', '中证红利'), isFalse);
    });
  });
}
