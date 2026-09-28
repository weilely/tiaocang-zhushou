import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/stock_detail.dart';

/// 股票资料三接口的解析（字段形状都是 **2026-09-28 真 Key 实测**的响应剪出来的）
void main() {
  group('估值快照', () {
    test('解析实测响应：带中文名 + PE/PB/PS/PCF', () {
      final v = StockValuation.fromJson({
        'code': 0,
        'message': 'success',
        'data': {
          'timestamp': 1790609105000,
          'total': 1,
          'item': [
            {
              'thscode': '000001.SZ',
              'ticker': '000001',
              'name': '平安银行',
              'pe_ttm': 5.045833,
              'pe_mrq': 4.266946,
              'pb_mrq': 0.468348,
              'ps_ttm': 1.652825,
              'pcf_ttm': 0.615649,
            }
          ],
        },
      })!;
      expect(v.name, '平安银行');
      expect(v.ticker, '000001');
      expect(v.peTtm, closeTo(5.0458, 1e-4));
      expect(v.peMrq, closeTo(4.2669, 1e-4));
      expect(v.pbMrq, closeTo(0.4683, 1e-4));
      expect(v.psTtm, closeTo(1.6528, 1e-4));
      expect(v.pcfTtm, closeTo(0.6156, 1e-4));
      expect(v.isEmpty, isFalse);
    });

    test('空 item（同花顺没覆盖的股票）→ null', () {
      expect(
        StockValuation.fromJson({
          'code': 0,
          'data': {'item': const []},
        }),
        isNull,
      );
    });

    test('指标全 null → isEmpty（界面按"没取到"处理）', () {
      final v = StockValuation.fromJson({
        'code': 0,
        'data': {
          'item': [
            {'thscode': '000001.SZ', 'name': '平安银行'}
          ],
        },
      })!;
      expect(v.isEmpty, isTrue);
      expect(v.name, '平安银行'); // 名字还是有的
    });
  });

  group('财务指标', () {
    Map<String, dynamic> resp() => {
          'code': 0,
          'data': {
            'thscode': '000001.SZ',
            'report': '2026-2',
            'abilities': [
              {
                'ability': 'growth',
                'indicators': [
                  {
                    'index_id': 'calculate_operating_income_yoy_growth_ratio',
                    'value': '1.77560000',
                  },
                  {'index_id': 'total_assets_growth_ratio', 'value': '1.7383'},
                  {'index_id': 'fixed_asset_invest_expansion_ratio', 'value': null},
                ],
              },
              {
                'ability': 'profitability',
                'indicators': [
                  {'index_id': 'index_weighted_avg_roe', 'value': '5.2200'},
                  // 实测银行类大量 null（没有毛利率）
                  {'index_id': 'sale_gross_margin', 'value': null},
                ],
              },
            ],
          },
        };

    test('解析能力分组与报告期', () {
      final f = StockFinancials.fromJson(resp());
      expect(f.report, '2026-2');
      expect(f.abilities.length, 2);
      expect(f.abilities.first.ability, 'growth');
      expect(f.indicator('total_assets_growth_ratio')!.num, closeTo(1.7383, 1e-4));
    });

    test('value 为 null 的指标：raw 空、num 空，nonNull 里不含它', () {
      final f = StockFinancials.fromJson(resp());
      final ind = f.indicator('sale_gross_margin')!;
      expect(ind.raw, isEmpty);
      expect(ind.num, isNull);
      final growth = f.abilities.first;
      expect(growth.nonNull.length, 2); // 3 条里去掉 1 条 null
      expect(
        growth.nonNull.map((e) => e.indexId),
        isNot(contains('fixed_asset_invest_expansion_ratio')),
      );
    });

    test('认不出的数值格式：num 是 null，但 raw 原文留着（界面照原样显示，不吞）', () {
      final f = StockFinancials.fromJson({
        'code': 0,
        'data': {
          'thscode': '600519.SH',
          'report': '2026-1',
          'abilities': [
            {
              'ability': 'growth',
              'indicators': [
                {'index_id': 'total_assets_growth_ratio', 'value': '--'}
              ],
            }
          ],
        },
      });
      final ind = f.indicator('total_assets_growth_ratio')!;
      expect(ind.num, isNull);
      expect(ind.raw, '--');
    });

    test('全部为空 → isEmpty', () {
      final f = StockFinancials.fromJson({
        'code': 0,
        'data': {
          'thscode': '000001.SZ',
          'report': '2026-2',
          'abilities': [
            {
              'ability': 'growth',
              'indicators': [
                {'index_id': 'total_assets_growth_ratio', 'value': null}
              ],
            }
          ],
        },
      });
      expect(f.isEmpty, isTrue);
    });
  });

  group('报告期候选（不写死年份）', () {
    test('9 月底 → 先试当年 2 季度（中报），再往前退', () {
      final c = stockReportCandidates(DateTime(2026, 9, 28));
      expect(c.first, '2026-2');
      expect(c.sublist(0, 4), ['2026-2', '2026-1', '2025-4', '2025-3']);
      expect(c.length, 6);
    });

    test('4 月初 → 先试当年 1 季度，退到去年 4 季度', () {
      final c = stockReportCandidates(DateTime(2026, 4, 3));
      expect(c.sublist(0, 3), ['2026-1', '2025-4', '2025-3']);
    });

    test('1 月初 → 跨年往回退', () {
      final c = stockReportCandidates(DateTime(2026, 1, 5));
      expect(c.sublist(0, 3), ['2025-4', '2025-3', '2025-2']);
    });
  });

  group('分红送配事件', () {
    test('解析 + 按除权日从新到旧', () {
      final list = parseStockDividendEvents({
        'code': 0,
        'data': {
          'thscode': '000001.SZ',
          'item': [
            {
              'ticker': '000001',
              'ex_date_ms': 1781193600000, // 较早
              'dividend_per_share': 0.36,
              'per_share_bonus': 0,
            },
            {
              'ticker': '000001',
              'ex_date_ms': 1790179200000, // 较新
              'dividend_per_share': 0.249,
              'per_share_bonus': 0,
            },
          ],
        },
      });
      expect(list.length, 2);
      expect(list.first.dividendPerShare, closeTo(0.249, 1e-6));
      expect(list.first.exDate!.isAfter(list.last.exDate!), isTrue);
    });

    test('送股也算一条；字段缺失不崩', () {
      final list = parseStockDividendEvents({
        'code': 0,
        'data': {
          'item': [
            {'ex_date_ms': 1790179200000, 'per_share_bonus': 0.3},
          ],
        },
      });
      expect(list.single.perShareBonus, closeTo(0.3, 1e-6));
      expect(list.single.isEmpty, isFalse);

      final none = parseStockDividendEvents({'code': 0, 'data': {'item': const []}});
      expect(none, isEmpty);
    });
  });

  group('打包：降级判据', () {
    final now = DateTime(2026, 9, 28);

    test('三块全空 → hasNothing（界面改成只看历史净值）', () {
      final b = StockDetailBundle(
        code: '000001',
        valuationError: '同花顺 code=1002 Unknown',
        financialsError: '没有取到财务指标',
        dividendsError: '同花顺请求超时',
        fetchedAt: now,
      );
      expect(b.hasNothing, isTrue);
    });

    test('只要有一块有数据，就不算"什么都没有"', () {
      final b = StockDetailBundle(
        code: '000001',
        valuation: const StockValuation(
          thscode: '000001.SZ',
          ticker: '000001',
          name: '平安银行',
          peTtm: 5,
        ),
        fetchedAt: now,
      );
      expect(b.hasNothing, isFalse);
    });

    test('★ 标注只在这 4 项真的出现值时才提示', () {
      StockDetailBundle withValue(String raw) => StockDetailBundle(
            code: '000001',
            financials: StockFinancials(
              thscode: '000001.SZ',
              report: '2026-2',
              abilities: [
                StockAbility(ability: 'growth', indicators: [
                  StockIndicator(
                    indexId: 'calculate_operating_income_yoy_growth_ratio',
                    raw: raw,
                    num: double.tryParse(raw),
                  ),
                ]),
              ],
            ),
            fetchedAt: now,
          );
      expect(withValue('1.77').hasUnofficialIndicators, isTrue);
      expect(withValue('').hasUnofficialIndicators, isFalse);
    });
  });

  group('界面配置：指标名与单位口径', () {
    test('配置里标了 ★ 的项必须都在"文档未收录"表里，且各自有中文名', () {
      expect(kFinIndicatorExtra.length, 4);
      for (final e in kFinIndicatorExtra.entries) {
        expect(e.value.trim(), isNotEmpty);
      }
      // 界面只挑其中一部分显示（不是 4 个都用），但用到的必须在表里
      final used = <String>{};
      for (final g in kFinGroups) {
        for (final r in g.rows) {
          if (r.unofficial) used.add(r.indexId);
        }
      }
      expect(used, isNotEmpty);
      expect(kFinIndicatorExtra.keys.toSet().containsAll(used), isTrue,
          reason: '界面上标 ★ 的项不在"文档未收录"表里：$used');
    });

    test('每个配置项要么在官方名表里、要么在 ★ 表里（不许出现没名字的）', () {
      for (final g in kFinGroups) {
        for (final r in g.rows) {
          final known =
              kFinIndicatorLabels.containsKey(r.indexId) || r.unofficial;
          expect(known, isTrue, reason: '${r.indexId} 既没有官方名也没标 ★');
        }
      }
    });

    test('百分比类才补 %：资产负债率是，流动比率/周转率不是', () {
      FinRow row(String id) => kFinGroups
          .expand((g) => g.rows)
          .firstWhere((r) => r.indexId == id);
      expect(row('assets_debt_ratio').percent, isTrue);
      expect(row('index_weighted_avg_roe').percent, isTrue);
      expect(row('current_ratio').percent, isFalse);
      expect(row('total_assets_turnover_ratio').percent, isFalse);
    });
  });
}
