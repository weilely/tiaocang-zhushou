import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/fund_detail.dart';

/// 同花顺「基金详情」三接口的**解析规则**
///
/// 这里用的 payload 是 2026-09-23 拿真 Key 实测回来的字段名（文档站有三处与实测
/// 不符，所以以实测为准）。全离线，不联网。
void main() {
  Map<String, dynamic> envelope(Object? data) => jsonDecode(jsonEncode({
        'code': 0,
        'message': 'success',
        'data': data,
      })) as Map<String, dynamic>;

  group('基金档案（fund/profile/detail）', () {
    test('实测字段全解析：公司 / 成立日 / 规模 / 净值 / 经理 / 交易规则 / 费率', () {
      final p = FundProfile.fromJson(envelope({
        'item': [
          {
            'thscode': '021362.OF',
            'ticker': '021362',
            'fund_name': '中证A',
            'estab_date': 1704067200000, // 2024-01-01
            'company_id': '80000234',
            'mgmt_name': '某某基金管理有限公司',
            'manager_name': '张三',
            'fund_scale': '12.34亿',
            'unit_nav': 1.2345,
            'manager_info': [
              {
                'manager_id': '3001',
                'manager_name': '张三',
                'tenure_return_pct': 12.5,
                'tenure_days': 900,
                'start_date_ms': 1704067200000,
              },
            ],
            'trade_rule': [
              {'title': '买入提交', 'display_time': '今日15点前', 'time_ms': 1},
              {'title': '确认份额', 'display_time': 'T+1', 'time_ms': 2},
            ],
            'rate_info': [
              {
                'rate_type': 'purchase',
                'charge_mode': 'front',
                'condition': '100万元以下',
                // 实测是字符串，不是数字 —— 按数字解析会全变 null
                'standard_rate': '1.20%',
                'discounted_rate': '0.12%',
              },
              {
                'rate_type': 'redemption',
                'charge_mode': 'default',
                'condition': '7天以下',
                'standard_rate': '1.50%',
                // 赎回没有折后价
              },
              {
                'rate_type': 'management',
                'charge_mode': 'ongoing',
                'standard_rate': '0.50%',
                // 管理费连档位都没有
              },
            ],
          },
        ],
      }));

      expect(p.thscode, '021362.OF');
      expect(p.ticker, '021362');
      expect(p.companyName, '某某基金管理有限公司');
      expect(p.estabDate!.year, 2024);
      expect(p.scale, '12.34亿');
      expect(p.unitNav, 1.2345);
      expect(p.isEmpty, isFalse);

      expect(p.managers.length, 1);
      expect(p.managers.first.name, '张三');
      expect(p.managers.first.tenureDays, 900);
      expect(p.managers.first.tenureReturnPct, 12.5);

      expect(p.tradeRules.length, 2);
      expect(p.tradeRules.first.title, '买入提交');
      expect(p.tradeRules.first.displayTime, '今日15点前');

      expect(p.rates.length, 3);
      expect(p.rates.first.type, 'purchase');
      expect(p.rates.first.condition, '100万元以下');
      expect(p.rates.first.standardRate, '1.20%');
      expect(p.rates.first.discountedRate, '0.12%');
      // 赎回没有折后价、管理费没有档位：都不能变成 null 或崩掉
      expect(p.rates[1].type, 'redemption');
      expect(p.rates[1].discountedRate, '');
      expect(p.rates[2].type, 'management');
      expect(p.rates[2].condition, '');
      expect(p.rates[2].standardRate, '0.50%');
      // 「1000元/笔」这种非百分比也要原样留着
      final perDeal = FundRate.fromJson({'standard_rate': '1000元/笔'});
      expect(perDeal.standardRate, '1000元/笔');
      expect(perDeal.hasRate, isTrue);
      expect(FundRate.fromJson({}).hasRate, isFalse);
    });

    test('字段缺失不炸、也不编：一律 null / 空列表，isEmpty 为真', () {
      final p = FundProfile.fromJson(envelope({'item': [{}]}));
      expect(p.ticker, '');
      expect(p.estabDate, isNull);
      expect(p.unitNav, isNull);
      expect(p.managers, isEmpty);
      expect(p.rates, isEmpty);
      expect(p.isEmpty, isTrue);
    });

    test('连 data.item 都没有（异常响应）：当成空档案，不抛', () {
      final p = FundProfile.fromJson(envelope(null));
      expect(p.isEmpty, isTrue);
    });

    test('unit_nav 为 0 与缺失是两回事：0 就是 0，null 才是没取到', () {
      final zero = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': '000001', 'unit_nav': 0}
        ]
      }));
      expect(zero.unitNav, 0);
      final missing = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': '000001'}
        ]
      }));
      expect(missing.unitNav, isNull);
    });

    test('规模：纯数字按万/亿紧凑显示，带单位的字符串原样显示', () {
      // 实测 021362 给的就是 261682632.55 这种没有单位的数字
      final numeric = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': '021362', 'fund_scale': 261682632.55}
        ]
      }));
      expect(numeric.scale, '261682632.55');
      expect(numeric.scaleText, '2.62亿');

      final small = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': 'x', 'fund_scale': 8000}
        ]
      }));
      expect(small.scaleText, '8000');

      final withUnit = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': 'x', 'fund_scale': '12.34亿'}
        ]
      }));
      expect(withUnit.scaleText, '12.34亿');

      final none = FundProfile.fromJson(envelope({
        'item': [
          {'ticker': 'x'}
        ]
      }));
      expect(none.scaleText, '');
    });
  });

  group('重仓股（fund/portfolio/holdings）', () {
    test('顶层仓位字段 + 明细逐条解析', () {
      final pf = FundPortfolio.fromJson(envelope({
        'total_stock_ratio_pct': 54.86,
        'stock_ratio_pct': 89.8,
        'main_industry': '周期',
        'concentration_ratio': 0.6109,
        'item': [
          {
            'thscode': '601899.SH',
            'ticker': '601899',
            'stock_name': '紫金矿业',
            'hold_ratio': 10.3,
            'position_capital': 123456789.0,
            'position_count': 1234.5,
            'security_market_value_rate_pct': 11.4,
            'period_increase_rate_pct': 0.5,
            'investment_rank': 1,
            'publish_date_ms': 1704067200000,
          },
        ],
      }));

      expect(pf.stockRatioPct, 89.8);
      expect(pf.mainIndustry, '周期');
      expect(pf.concentrationRatio, 0.6109);
      expect(pf.holdings.length, 1);
      expect(pf.holdings.first.name, '紫金矿业');
      expect(pf.holdings.first.ticker, '601899');
      expect(pf.holdings.first.holdRatio, 10.3);
      expect(pf.holdings.first.rank, 1);
      expect(pf.publishDate!.year, 2024);
      expect(pf.isEmpty, isFalse);
    });

    test('空响应 = isEmpty（债基/货基本来就没有重仓股）', () {
      final pf = FundPortfolio.fromJson(envelope(null));
      expect(pf.holdings, isEmpty);
      expect(pf.publishDate, isNull);
      expect(pf.isEmpty, isTrue);
    });

    test('报告期取明细里最新的一条', () {
      final pf = FundPortfolio.fromJson(envelope({
        'item': [
          {'ticker': '1', 'stock_name': 'A', 'publish_date_ms': 1704067200000},
          {'ticker': '2', 'stock_name': 'B', 'publish_date_ms': 1735689600000},
        ],
      }));
      expect(pf.publishDate!.year, 2025);
    });
  });

  group('分红（fund/corporate-actions/dividends）', () {
    test('count / 每10份税前税后 / 各日期解析，并按除息日倒序', () {
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 2,
        'dividend_total': '0.35元/份',
        'item': [
          {
            'per_ten_cash_before_tax': 0.5,
            'per_ten_cash_after_tax': 0.45,
            'progress': '实施',
            'publish_date_ms': 1735689600000,
            'registration_date_ms': 1735776000000,
            'ex_dividend_date_ms': 1735862400000,
            'payment_date_ms': 1735948800000,
            'reinvestment_date_ms': 1735862400000,
          },
          {
            'per_ten_cash_before_tax': 1.2,
            'per_ten_cash_after_tax': 1.08,
            'progress': '实施',
            'registration_date_ms': 1704067200000,
            'ex_dividend_date_ms': 1704153600000,
          },
        ],
      }));

      expect(d.count, 2);
      expect(d.total, '0.35元/份');
      expect(d.totalText, '0.35元/份');
      expect(d.items.length, 2);
      // 先按除息日倒序：2025 年初那次在前、2024 年初那次在后
      expect(d.items.first.perTenBeforeTax, 0.5);
      expect(d.items.first.perTenAfterTax, 0.45);
      expect(d.items.first.progress, '实施');
      expect(d.items.first.reinvestmentDate, isNotNull);
      expect(d.items.last.perTenBeforeTax, 1.2);
      expect(d.items.last.registrationDate!.year, 2024);
      expect(d.isEmpty, isFalse);
    });

    test('「该基金没分红」= count 0 且没有明细（confirmedEmpty）', () {
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 0,
        'dividend_total': '',
        'item': [],
      }));
      expect(d.count, 0);
      expect(d.items, isEmpty);
      expect(d.isEmpty, isTrue);
      expect(d.confirmedEmpty, isTrue);
    });

    test('全 null 的占位记录被丢掉（021362 实测：count=0 却回了一条空记录）', () {
      // 真凭证探到的原样：count 0 / total 0.0 / item 里一条每个字段都是 null
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 0,
        'dividend_total': 0.0,
        'item': [
          {
            'per_ten_cash_before_tax': null,
            'per_ten_cash_after_tax': null,
            'progress': null,
            'publish_date_ms': null,
            'registration_date_ms': null,
            'ex_dividend_date_ms': null,
            'payment_date_ms': null,
            'reinvestment_date_ms': null,
            'profit_base_date_ms': null,
            'in_dividend_date_ms': null,
          },
        ],
      }));
      expect(d.items, isEmpty, reason: '空记录不该在界面上占一行');
      expect(d.isEmpty, isTrue);
      expect(d.confirmedEmpty, isTrue, reason: '能放心说"这只基金没分过红"');
      expect(d.totalText, isNull, reason: '「累计分红 0.0」不该显示');
    });

    test('有内容的记录不会被误杀（只有日期、没有金额也算有内容）', () {
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 1,
        'item': [
          {'ex_dividend_date_ms': 1704153600000},
        ],
      }));
      expect(d.items.length, 1);
      expect(d.items.first.exDividendDate!.year, 2024);
      expect(d.totalText, isNull);
    });

    test('count 在外层信封上也能取到（实测有的计数字段不在 data 里）', () {
      final raw = jsonDecode(jsonEncode({
        'code': 0,
        'dividend_count': 3,
        'data': {'item': []},
      })) as Map<String, dynamic>;
      final d = FundDividends.fromJson(raw);
      expect(d.count, 3);
      // 有 count 但没有明细：不算"确认无分红"
      expect(d.isEmpty, isFalse);
      expect(d.confirmedEmpty, isFalse);
    });

    test('count 缺失时是 null（不拿列表长度冒充分红总次数）', () {
      final d = FundDividends.fromJson(envelope({
        'item': [
          {'per_ten_cash_before_tax': 0.5, 'ex_dividend_date_ms': 1704067200000}
        ],
      }));
      expect(d.count, isNull);
      expect(d.items.length, 1);
      expect(d.isEmpty, isFalse);
    });

    test('累计分红的浮点噪声要去掉，并补上单位（024564 实测 0.018000000000000002）', () {
      // 两次分红是「每10份 0.0800 / 0.1000 元」→ 每份累计 0.018
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 2,
        'dividend_total': 0.018000000000000002,
        'item': [
          {'per_ten_cash_before_tax': 0.08, 'ex_dividend_date_ms': 1784073600000},
          {'per_ten_cash_before_tax': 0.1, 'ex_dividend_date_ms': 1775779200000},
        ],
      }));
      expect(d.totalText, '0.018');
      expect(d.totalLabel, '0.018 元/份');
    });

    test('累计分红已经是带单位的字符串时原样显示，不重复加单位', () {
      final d = FundDividends.fromJson(envelope({
        'dividend_count': 1,
        'dividend_total': '0.35元/份',
        'item': [
          {'per_ten_cash_before_tax': 0.5, 'ex_dividend_date_ms': 1704067200000}
        ],
      }));
      expect(d.totalLabel, '0.35元/份');
    });

    test('分红进度是纯数字状态码时不显示（024564 回的是 "2"）', () {
      final numeric =
          FundDividend.fromJson({'progress': '2', 'ex_dividend_date_ms': 1704067200000});
      expect(numeric.progress, '2');
      expect(numeric.progressText, '');
      final chinese = FundDividend.fromJson(
          {'progress': '实施', 'ex_dividend_date_ms': 1704067200000});
      expect(chinese.progressText, '实施');
    });
  });
}
