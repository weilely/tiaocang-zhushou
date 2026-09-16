import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/portfolio.dart';
import 'package:invest_tracker/logic/returns_calendar.dart';

/// 逐日序列引擎：口径必须与 `Portfolio` 的移动加权平均成本法一致
void main() {
  Asset fund({int id = 1, String code = '025497', String name = '测试基金A'}) =>
      Asset(id: id, code: code, name: name, kind: AssetKind.fund);

  NavPoint nav(String code, String date, double v) =>
      NavPoint(code: code, date: date, nav: v, accNav: v);

  Txn buy({
    int assetId = 1,
    int accountId = 1,
    required String date,
    required double amount,
    required double shares,
    double fee = 0,
  }) =>
      Txn(
        accountId: accountId,
        assetId: assetId,
        type: TxnType.buy,
        date: DateTime.parse(date),
        amount: amount,
        shares: shares,
        price: shares > 0 ? amount / shares : 0,
        fee: fee,
      );

  Txn sell({
    int assetId = 1,
    int accountId = 1,
    required String date,
    required double amount,
    required double shares,
    double fee = 0,
  }) =>
      Txn(
        accountId: accountId,
        assetId: assetId,
        type: TxnType.sell,
        date: DateTime.parse(date),
        amount: amount,
        shares: shares,
        price: shares > 0 ? amount / shares : 0,
        fee: fee,
      );

  Txn dividend({
    int assetId = 1,
    int accountId = 1,
    required String date,
    required double amount,
  }) =>
      Txn(
        accountId: accountId,
        assetId: assetId,
        type: TxnType.dividend,
        date: DateTime.parse(date),
        amount: amount,
      );

  group('每日盈亏', () {
    test('买入后每日盈亏 = 当日份额 × 净值差', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.10),
          nav(a.code, '2026-09-10', 1.05),
        ]),
      ];
      final txns = [buy(date: '2026-09-08', amount: 1000, shares: 1000)];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 10),
      );

      expect(s.length, 3);
      expect(s[0].dayPnl, closeTo(0, 1e-9), reason: '首条净值没有上一价，记 0');
      expect(s[1].dayPnl, closeTo(1000 * 0.10, 1e-9));
      expect(s[2].dayPnl, closeTo(1000 * -0.05, 1e-9));
    });

    test('净值没更新的交易日按前向填充，当日盈亏为 0', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-10', 1.00),
          nav(a.code, '2026-09-11', 1.10),
          // 09-12 缺（周末），09-13 有
          nav(a.code, '2026-09-13', 1.20),
        ]),
      ];
      final txns = [buy(date: '2026-09-10', amount: 1000, shares: 1000)];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 10),
        end: DateTime(2026, 9, 13),
      );

      // 只有 3 个有净值的日子，缺净值的日子不产生点（日历里自然是空格）
      expect(s.length, 3);
      expect(s.map((p) => p.date.day).toList(), [10, 11, 13]);
      expect(s.last.dayPnl, closeTo(1000 * 0.10, 1e-9));
    });

    test('两只标的净值日不一致：当天没有新净值的那只不能把上次涨跌再算一遍', () {
      // A 每个交易日都有净值；B 只有 09-10（09-11 停牌 / QDII 滞后 / 缺数据）
      final a = fund(id: 1, code: 'AAA', name: 'A');
      final b = fund(id: 2, code: 'BBB', name: 'B');
      final series = [
        AssetSeries(asset: a, navs: [
          nav('AAA', '2026-09-10', 1.00),
          nav('AAA', '2026-09-11', 1.10),
        ]),
        AssetSeries(asset: b, navs: [
          nav('BBB', '2026-09-09', 2.00),
          nav('BBB', '2026-09-10', 2.20),
        ]),
      ];
      final txns = [
        buy(assetId: 1, date: '2026-09-10', amount: 1000, shares: 1000),
        buy(assetId: 2, date: '2026-09-09', amount: 1000, shares: 500),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 9),
        end: DateTime(2026, 9, 11),
      );

      // 09-10：A 首条净值记 0；B 从 2.00 → 2.20，500 份 → +100
      final d10 = s.firstWhere((p) => p.date.day == 10);
      expect(d10.dayPnl, closeTo(500 * 0.20, 1e-9));

      // 09-11：只有 A 有新净值（1000 份 × 0.10 = +100）；
      // B 当天没有新净值，**不能再把 09-10 的 +100 重复计一次**
      final d11 = s.firstWhere((p) => p.date.day == 11);
      expect(d11.dayPnl, closeTo(1000 * 0.10, 1e-9),
          reason: '没有新净值的那只应当记 0，而不是重复上次涨跌');
    });

    test('日收益之和 = 区间内累计收益的变化（有标的缺净值时也要成立）', () {
      final a = fund(id: 1, code: 'AAA', name: 'A');
      final b = fund(id: 2, code: 'BBB', name: 'B');
      final series = [
        AssetSeries(asset: a, navs: [
          nav('AAA', '2026-09-09', 1.00),
          nav('AAA', '2026-09-10', 1.05),
          nav('AAA', '2026-09-11', 1.02),
        ]),
        AssetSeries(asset: b, navs: [
          nav('BBB', '2026-09-09', 2.00),
          // 09-10 缺
          nav('BBB', '2026-09-11', 2.30),
        ]),
      ];
      final txns = [
        buy(assetId: 1, date: '2026-09-09', amount: 1000, shares: 1000),
        buy(assetId: 2, date: '2026-09-09', amount: 1000, shares: 500),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 9),
        end: DateTime(2026, 9, 11),
      );

      final sum = s.fold<double>(0, (acc, p) => acc + p.dayPnl);
      final delta = s.last.cumPnl - s.first.cumPnl;
      expect(sum, closeTo(delta, 1e-9),
          reason: '逐日之和必须等于累计收益的变化，重复计入会破坏这个恒等式');
    });

    test('部分卖出后份额减少，每日盈亏随之变化；清仓后为 0', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.00),
          nav(a.code, '2026-09-10', 1.10),
          nav(a.code, '2026-09-11', 1.20),
        ]),
      ];
      final txns = [
        buy(date: '2026-09-08', amount: 1000, shares: 1000),
        sell(date: '2026-09-09', amount: 400, shares: 400),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 11),
      );

      // 09-09 卖出后剩 600 份
      expect(s[2].dayPnl, closeTo(600 * 0.10, 1e-9));

      // 09-10 全部清仓后再看 09-11，份额为 0
      final s2 = buildDailySeries(
        assets: series,
        txns: [
          ...txns,
          sell(date: '2026-09-10', amount: 660, shares: 600),
        ],
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 11),
      );
      expect(s2.last.dayPnl, closeTo(0, 1e-9), reason: '已清仓');
    });

    test('清仓的标的仍留在日历里：持有期间的日子照样有点，清仓之后才是 0', () {
      // 用户会问：卖完的基金是不是就没数据了？—— 不是。
      // 只要**交易记录还在**，它就还在 trackedAssets 里，日历也照常算它。
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-01', 1.00),
          nav(a.code, '2026-09-02', 1.10),
          nav(a.code, '2026-09-03', 1.20),
        ]),
      ];
      final txns = [
        buy(date: '2026-09-01', amount: 1000, shares: 1000),
        sell(date: '2026-09-02', amount: 1100, shares: 1000), // 全额卖出
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 3),
      );

      // 三个净值日都产生了点（不是空洞）
      expect(s.length, 3);
      expect(s.map((p) => p.date.day).toList(), [1, 2, 3]);

      // 卖出当天份额已归零 → 当日盈亏 0；之后也是 0
      expect(s[1].dayPnl, closeTo(0, 1e-9));
      expect(s[2].dayPnl, closeTo(0, 1e-9));

      // 日历上这三天都得有格子（amount 非空），只是值为 0
      // 2026-09-01 是周二 → 网格周日起始，前两格是空位
      final cells = cellsForMonth(s, 2026, 9);
      expect(cells[2].label, '1');
      expect(cells[2].amount, isNotNull, reason: '9-1 买入当天');
      expect(cells[3].amount, isNotNull, reason: '9-2 卖出当天');
      expect(cells[4].amount, isNotNull, reason: '9-3 已清仓');
      expect(cells[2].amount, closeTo(0, 1e-9));
    });

    test('分红不改变份额，但进「已收回」', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.00),
        ]),
      ];
      final txns = [
        buy(date: '2026-09-08', amount: 1000, shares: 1000),
        dividend(date: '2026-09-09', amount: 30),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      // 份额仍是 1000，净值没动 → 当日盈亏 0；但累计盈亏多了 30
      expect(s.last.dayPnl, closeTo(0, 1e-9));
      expect(s.last.cumPnl, closeTo(30, 1e-9));
    });
  });

  group('与 Portfolio 口径一致（最关键的一条）', () {
    test('cumPnl(最后一日) == 浮动盈亏 + 已实现收益', () {
      final a1 = fund(id: 1, code: '025497', name: '基金A');
      final a2 = fund(id: 2, code: '510300', name: '基金B');

      final series = [
        AssetSeries(asset: a1, navs: [
          nav(a1.code, '2026-09-08', 1.00),
          nav(a1.code, '2026-09-09', 1.20),
          nav(a1.code, '2026-09-10', 1.30),
        ]),
        AssetSeries(asset: a2, navs: [
          nav(a2.code, '2026-09-08', 2.00),
          nav(a2.code, '2026-09-09', 1.80),
          nav(a2.code, '2026-09-10', 1.90),
        ]),
      ];

      final txns = [
        buy(assetId: 1, date: '2026-09-08', amount: 1000, shares: 1000, fee: 5),
        buy(assetId: 2, date: '2026-09-08', amount: 2000, shares: 1000, fee: 5),
        sell(assetId: 1, date: '2026-09-09', amount: 600, shares: 500, fee: 2),
        dividend(assetId: 2, date: '2026-09-09', amount: 20),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 10),
      );

      // 用同一组「最新价」跑一遍 Portfolio，两边必须对齐
      final quotes = {
        a1.code: Quote(code: a1.code, kind: AssetKind.fund, price: 1.30),
        a2.code: Quote(code: a2.code, kind: AssetKind.fund, price: 1.90),
      };
      final positions = buildPositions(
        txns: txns,
        assets: {1: a1, 2: a2},
        quotes: quotes,
      );
      final summary = summarize(positions);

      expect(s.last.cumPnl, closeTo(summary.cumulativePnl, 1e-6),
          reason: '逐日引擎的累计盈亏必须等于 Portfolio 的累计收益');
    });

    test('超卖时两边同样按可卖份额折算', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.00),
        ]),
      ];
      final txns = [
        buy(date: '2026-09-08', amount: 1000, shares: 1000),
        // 只有 1000 份却卖 1500 份
        sell(date: '2026-09-09', amount: 1500, shares: 1500),
      ];

      final s = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      final positions = buildPositions(
        txns: txns,
        assets: {1: a},
        quotes: {a.code: Quote(code: a.code, kind: AssetKind.fund, price: 1.0)},
      );

      expect(s.last.cumPnl,
          closeTo(summarize(positions).cumulativePnl, 1e-6));
    });
  });

  group('网格聚合', () {
    final a = fund();
    // 故意把 2025-12-31 放在最后：净值乱序传入时引擎必须自己排序，
    // 否则双指针会静默算错（这条同时是防回归）
    final series = buildDailySeries(
      assets: [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-08-31', 1.00),
          nav(a.code, '2026-09-01', 1.10),
          nav(a.code, '2026-09-02', 1.20),
          nav(a.code, '2026-10-01', 1.30),
          nav(a.code, '2025-12-31', 0.90),
        ]),
      ],
      txns: [buy(date: '2026-08-31', amount: 1000, shares: 1000)],
      start: DateTime(2025, 12, 31),
      end: DateTime(2026, 10, 1),
    );

    test('月网格恒为 42 格，1 号落在正确位置', () {
      final cells = cellsForMonth(series, 2026, 9);
      expect(cells.length, 42);
      // 2026-09-01 是周二 → 周日起始的索引 2
      expect(cells[2].label, '1');
      expect(cells[2].amount, closeTo(1000 * 0.10, 1e-9));
      expect(cells[3].label, '2');
      expect(cells[3].amount, closeTo(1000 * 0.10, 1e-9));
      // 没有数据的格子只留标签
      expect(cells[4].label, '3');
      expect(cells[4].amount, isNull);
    });

    test('月聚合 = 该月逐日之和', () {
      final cells = cellsForYear(series, 2026);
      expect(cells.length, 12);
      final aug = cells[7]; // 8 月
      expect(aug.label, '8月');
      expect(aug.amount, closeTo(1000 * 0.10, 1e-9),
          reason: '08-31 相对 2025-12-31 的 0.90 涨到 1.00');
      final sep = cells[8]; // 9 月
      expect(sep.label, '9月');
      expect(sep.amount, closeTo(1000 * 0.20, 1e-9), reason: '9 月两天各 +100');
      final oct = cells[9];
      expect(oct.amount, closeTo(1000 * 0.10, 1e-9));
      // 没有数据的月份只留标签
      expect(cells[0].label, '1月');
      expect(cells[0].amount, isNull);
    });

    test('年聚合按年分组', () {
      final cells = cellsForYears(series);
      expect(cells.map((c) => c.label).toList(), ['2025', '2026']);
      expect(cells.first.amount, closeTo(0, 1e-9), reason: '2025 只有一天且无上一价');
      expect(cells.last.amount, closeTo(1000 * 0.40, 1e-9));
    });
  });

  group('区间收益率曲线', () {
    final a = fund();
    final series = buildDailySeries(
      assets: [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-08-31', 1.00),
          nav(a.code, '2026-09-01', 1.10),
          nav(a.code, '2026-09-02', 1.20),
        ]),
      ],
      txns: [buy(date: '2026-08-31', amount: 1000, shares: 1000)],
      start: DateTime(2026, 8, 31),
      end: DateTime(2026, 9, 2),
    );

    test('起点归零，最后一点就是阶段收益', () {
      final pts = windowReturnSeries(series, DateTime(2026, 9, 1), DateTime(2026, 9, 2));
      expect(pts.first.date, DateTime(2026, 9, 1));
      expect(pts.first.pct, closeTo(0, 1e-9), reason: '起点锚点为 0');
      // 09-01 涨到 1.10 → 相对 08-31 的 1.00 是 +10%
      expect(pts[1].pct, closeTo(10, 1e-6));
      // 09-02 涨到 1.20 → 相对 08-31 是 +20%
      expect(pts.last.pct, closeTo(20, 1e-6));
    });

    test('空序列返回空', () {
      expect(windowReturnSeries(const [], DateTime(2026, 1, 1), DateTime(2026, 2, 1)),
          isEmpty);
    });
  });

  group('边界与空数据', () {
    test('没有标的 / 没有净值 → 空序列不抛', () {
      expect(
        buildDailySeries(
          assets: const [],
          txns: const [],
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 31),
        ),
        isEmpty,
      );
      final a = fund();
      expect(
        buildDailySeries(
          assets: [AssetSeries(asset: a, navs: const [])],
          txns: const [],
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 31),
        ),
        isEmpty,
      );
    });

    test('开始晚于结束 → 空序列', () {
      final a = fund();
      expect(
        buildDailySeries(
          assets: [
            AssetSeries(asset: a, navs: [nav(a.code, '2026-09-01', 1.0)]),
          ],
          txns: const [],
          start: DateTime(2026, 9, 10),
          end: DateTime(2026, 9, 1),
        ),
        isEmpty,
      );
    });

    test('账户过滤只统计该账户的流水', () {
      final a = fund();
      final series = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.00),
        ]),
      ];
      final txns = [
        buy(accountId: 1, date: '2026-09-08', amount: 1000, shares: 1000),
        buy(accountId: 2, date: '2026-09-08', amount: 500, shares: 500),
      ];

      final all = buildDailySeries(
        assets: series,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      final only1 = buildDailySeries(
        assets: series,
        txns: txns,
        accountId: 1,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      expect(all.last.cumPnl, closeTo(0, 1e-9));
      expect(only1.last.cumPnl, closeTo(0, 1e-9));
      // 两边份额不同，用一次净值变化区分
      final series2 = [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2026-09-08', 1.00),
          nav(a.code, '2026-09-09', 1.10),
        ]),
      ];
      final all2 = buildDailySeries(
        assets: series2,
        txns: txns,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      final only2 = buildDailySeries(
        assets: series2,
        txns: txns,
        accountId: 1,
        start: DateTime(2026, 9, 8),
        end: DateTime(2026, 9, 9),
      );
      expect(all2.last.dayPnl, closeTo(1500 * 0.10, 1e-9));
      expect(only2.last.dayPnl, closeTo(1000 * 0.10, 1e-9));
    });

    test('缺净值的标的退回成本单价估值，并被标记出来', () {
      final a = fund();
      final snap = holdingValueOn(
        assets: [AssetSeries(asset: a, navs: const [])],
        txns: [buy(date: '2026-09-08', amount: 1000, shares: 1000)],
        asOf: DateTime(2026, 9, 9),
      );
      expect(snap.value, closeTo(1000, 1e-9));
      expect(snap.missingNav, [a.code]);
    });
  });

  group('区间内的买入/卖出/分红汇总', () {
    test('与逐日引擎同口径（含超卖折算）', () {
      final txns = [
        buy(assetId: 1, date: '2026-09-01', amount: 1000, shares: 1000),
        buy(assetId: 1, date: '2026-09-20', amount: 500, shares: 500),
        sell(assetId: 1, date: '2026-09-10', amount: 300, shares: 300, fee: 1),
        dividend(assetId: 1, date: '2026-09-11', amount: 25),
      ];
      final f = flowTotals(
        txns: txns,
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 15),
      );
      expect(f.invest, closeTo(1000, 1e-9), reason: '09-20 那笔在区间外');
      expect(f.redeem, closeTo(299, 1e-9));
      expect(f.dividend, closeTo(25, 1e-9));
    });
  });

  group('当前视图区间的合计（日历图那行「累计收益」）', () {
    // 本组单独的序列：跨 2025/2026 两年，含一个没有数据的月份
    final a = fund();
    final series = buildDailySeries(
      assets: [
        AssetSeries(asset: a, navs: [
          nav(a.code, '2025-12-31', 0.90),
          nav(a.code, '2026-08-31', 1.00),
          nav(a.code, '2026-09-01', 1.10),
          nav(a.code, '2026-09-02', 1.20),
          nav(a.code, '2026-10-01', 1.30),
        ]),
      ],
      txns: [buy(date: '2025-12-31', amount: 900, shares: 1000)],
      start: DateTime(2025, 12, 31),
      end: DateTime(2026, 10, 1),
    );

    test('periodPnlOf = 各格之和', () {
      expect(periodPnlOf(cellsForMonth(series, 2026, 9)),
          closeTo(sumCells(cellsForMonth(series, 2026, 9)), 1e-9));
      expect(periodPnlOf(cellsForMonth(series, 2026, 9)),
          closeTo(1000 * 0.20, 1e-9),
          reason: '8/31 相对 2025-12-31 的 0.90 涨到 1.00（在 8 月），9 月两天各 +100');
    });

    test('整屏无数据返回 null（显示 -- 而不是 ¥0.00）', () {
      expect(periodPnlOf(cellsForMonth(series, 2025, 3)), isNull);
      expect(periodPnlOf(const []), isNull);
      expect(
          periodPnlOf(const [PnlCell(label: '1'), PnlCell(label: '2')]), isNull);
    });

    test('盈亏恰好为 0 时返回 0，不是 null', () {
      final cells = [const PnlCell(label: '1', amount: 0)];
      expect(periodPnlOf(cells), 0);
      expect(periodPnlOf(cells), isNotNull);
    });

    test('部分有金额时只累加有金额的格子', () {
      final cells = [
        const PnlCell(label: '1', amount: 120),
        const PnlCell(label: '2'),
        const PnlCell(label: '3', amount: -20),
      ];
      expect(periodPnlOf(cells), closeTo(100, 1e-9));
    });

    test('三种粒度自洽：年 == 各月之和 == 年格子里的那一格', () {
      for (final y in [2025, 2026]) {
        final byYear = sumCells(cellsForYear(series, y));
        var byMonths = 0.0;
        for (var m = 1; m <= 12; m++) {
          byMonths += sumCells(cellsForMonth(series, y, m));
        }
        final cell = cellsForYears(series).firstWhere((c) => c.label == '$y');

        expect(byMonths, closeTo(byYear, 1e-9),
            reason: '$y 年：12 个月各自之和应等于年格子的值');
        expect(cell.amount, closeTo(byYear, 1e-9),
            reason: '$y 年：年粒度那一格应等于该年合计');
      }
    });

    test('年粒度的总和等于各年份之和', () {
      final years = cellsForYears(series);
      var sum = 0.0;
      for (final c in years) {
        sum += c.amount ?? 0;
      }
      expect(periodPnlOf(years), closeTo(sum, 1e-9));
      expect(sum, closeTo(1000 * 0.40, 1e-9), reason: '四个交易日各 +100');
    });
  });
}
