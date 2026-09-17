import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/core/format.dart';
import 'package:invest_tracker/data/market_api.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/dca_models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/backup.dart';
import 'package:invest_tracker/logic/csv_io.dart';
import 'package:invest_tracker/logic/portfolio.dart';

void main() {
  // ---------------- 成本核算与盈亏 ----------------

  group('成本核算（移动加权平均）', () {
    final asset = Asset(id: 1, code: '600519', name: '贵州茅台', kind: AssetKind.stock, market: 'SH');
    final assets = {1: asset};

    test('两次买入后平均成本、浮动盈亏正确', () {
      final txns = [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 1, 5),
            amount: 1000,
            shares: 100,
            price: 10),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 2, 5),
            amount: 2000,
            shares: 100,
            price: 20),
      ];
      final quotes = {
        '600519': Quote(code: '600519', kind: AssetKind.stock, price: 25, prevClose: 24),
      };

      final ps = buildPositions(txns: txns, assets: assets, quotes: quotes);
      expect(ps.length, 1);
      final p = ps.first;
      expect(p.shares, closeTo(200, 1e-9));
      expect(p.cost, closeTo(3000, 1e-9));
      expect(p.avgCost, closeTo(15, 1e-9));
      expect(p.marketValue, closeTo(5000, 1e-9));
      expect(p.floating, closeTo(2000, 1e-9));
      expect(p.floatingPct, closeTo(66.666, 0.01));
      expect(p.realized, closeTo(0, 1e-9));
      expect(p.totalPnl, closeTo(2000, 1e-9));
    });

    test('部分卖出后已实现收益与剩余成本正确', () {
      final txns = [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 1, 5),
            amount: 1000,
            shares: 100,
            price: 10),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 2, 5),
            amount: 2000,
            shares: 100,
            price: 20),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.sell,
            date: DateTime(2026, 3, 5),
            amount: 3000,
            shares: 100,
            price: 30,
            fee: 5),
      ];

      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.shares, closeTo(100, 1e-9));
      expect(p.cost, closeTo(1500, 1e-9));
      expect(p.avgCost, closeTo(15, 1e-9));
      // 已实现 = (3000 - 5) - 15×100 = 1495
      expect(p.realized, closeTo(1495, 1e-9));
      expect(p.invested, closeTo(3000, 1e-9));
      expect(p.returned, closeTo(2995, 1e-9));
    });

    test('分红计入已实现收益，不改变持仓成本', () {
      final txns = [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 1, 5),
            amount: 1000,
            shares: 100,
            price: 10),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.dividend,
            date: DateTime(2026, 6, 5),
            amount: 88),
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.cost, closeTo(1000, 1e-9));
      expect(p.shares, closeTo(100, 1e-9));
      expect(p.realized, closeTo(88, 1e-9));
    });

    test('全部卖出后份额与成本归零', () {
      final txns = [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 1, 5),
            amount: 1000,
            shares: 100,
            price: 10),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.sell,
            date: DateTime(2026, 3, 5),
            amount: 1200,
            shares: 100,
            price: 12),
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.isEmpty, isTrue);
      expect(p.shares, 0);
      expect(p.cost, 0);
      expect(p.realized, closeTo(200, 1e-9));
    });
  });

  // ---------------- XIRR ----------------

  group('年化收益率 XIRR', () {
    test('一年翻 10% 的场景', () {
      final flows = [
        CashFlow(DateTime(2025, 1, 1), -1000),
        CashFlow(DateTime(2026, 1, 1), 1100),
      ];
      expect(xirr(flows), closeTo(0.10, 0.002));
    });

    test('刚好回本的年化约等于 0', () {
      final flows = [
        CashFlow(DateTime(2025, 1, 1), -1000),
        CashFlow(DateTime(2026, 1, 1), 1000),
      ];
      expect(xirr(flows), closeTo(0, 0.002));
    });

    test('分两笔投入、两年后赎回', () {
      final flows = [
        CashFlow(DateTime(2024, 1, 1), -5000),
        CashFlow(DateTime(2025, 1, 1), -5000),
        CashFlow(DateTime(2026, 1, 1), 12000),
      ];
      final r = xirr(flows);
      expect(r, greaterThan(0.05));
      expect(r, lessThan(0.30));
    });

    test('现金流同向时无解，返回 NaN', () {
      expect(
        xirr([CashFlow(DateTime(2025, 1, 1), -1000), CashFlow(DateTime(2026, 1, 1), -500)])
            .isNaN,
        isTrue,
      );
    });
  });

  // ---------------- 再平衡 ----------------

  group('持仓分布图例的顺序', () {
    test('按占比升序（首页图例与圆环共用这一份顺序）', () {
      final slices = sortSlicesAscending(const [
        AllocationSlice(key: 'asset:A', label: 'A', value: 300, ratio: 0.6),
        AllocationSlice(key: 'asset:B', label: 'B', value: 50, ratio: 0.1),
        AllocationSlice(key: 'asset:C', label: 'C', value: 150, ratio: 0.3),
      ]);
      expect(slices.map((s) => s.label).toList(), ['B', 'C', 'A']);
      // 占比与合计都不受影响
      expect(slices.map((s) => s.ratio).toList(), [0.1, 0.3, 0.6]);
      expect(slices.fold<double>(0, (a, s) => a + s.value), 500);
    });

    test('不改动原列表', () {
      const src = [
        AllocationSlice(key: 'asset:A', label: 'A', value: 300, ratio: 0.6),
        AllocationSlice(key: 'asset:B', label: 'B', value: 50, ratio: 0.1),
      ];
      sortSlicesAscending(src);
      expect(src.first.label, 'A', reason: '必须是新列表，不能就地改');
    });
  });

  group('再平衡计算', () {
    final actual = [
      const AllocationSlice(key: 'cat:股票', label: '股票', value: 7000, ratio: 0.7),
      const AllocationSlice(key: 'cat:债券', label: '债券', value: 3000, ratio: 0.3),
    ];
    final targets = [
      TargetAlloc(key: 'cat:股票', label: '股票', ratio: 0.6),
      TargetAlloc(key: 'cat:债券', label: '债券', ratio: 0.4),
    ];

    test('超配识别与建议卖出金额', () {
      final items = computeRebalance(
        actual: actual,
        targets: targets,
        totalValue: 10000,
        threshold: 0.05,
      );
      final stock = items.firstWhere((i) => i.key == 'cat:股票');
      expect(stock.diffRatio, closeTo(0.10, 1e-9));
      expect(stock.needsRebalance, isTrue);
      expect(stock.direction, '超配');
      expect(stock.suggestAmount(10000), closeTo(-1000, 1e-9));

      final bond = items.firstWhere((i) => i.key == 'cat:债券');
      expect(bond.needsRebalance, isTrue);
      expect(bond.direction, '低配');
      expect(bond.suggestAmount(10000), closeTo(1000, 1e-9));
    });

    test('偏离小于阈值时不告警', () {
      final items = computeRebalance(
        actual: actual,
        targets: targets,
        totalValue: 10000,
        threshold: 0.15,
      );
      expect(items.every((i) => !i.needsRebalance), isTrue);
    });

    test('目标中缺失的类别视为 0 占比（全低配）', () {
      final items = computeRebalance(
        actual: actual,
        targets: [TargetAlloc(key: 'cat:现金', label: '现金', ratio: 0.2)],
        totalValue: 10000,
        threshold: 0.05,
      );
      expect(items.length, 1);
      expect(items.first.actualRatio, 0);
      expect(items.first.suggestAmount(10000), closeTo(2000, 1e-9));
    });
  });

  // ---------------- CSV ----------------

  group('CSV 编解码', () {
    test('导出后再导入，数据一致', () {
      final asset = Asset(id: 1, code: '000001', name: '华夏成长混合', kind: AssetKind.fund);
      final account = Account(id: 1, name: '天天基金');
      final txns = [
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 1, 5),
            amount: 1000,
            shares: 797.45,
            price: 1.254,
            fee: 1.5),
        Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.dividend,
            date: DateTime(2026, 6, 5),
            amount: 88.8),
      ];

      final csv = exportTxnsCsv(txns, {1: account}, {1: asset});
      final parsed = parseTxnCsv(csv);

      expect(parsed.errors, isEmpty);
      expect(parsed.rows.length, 2);
      expect(parsed.rows[0].code, '000001');
      expect(parsed.rows[0].type, TxnType.buy);
      expect(parsed.rows[0].accountName, '天天基金');
      expect(parsed.rows[0].shares, closeTo(797.45, 1e-6));
      expect(parsed.rows[0].fee, closeTo(1.5, 1e-6));
      expect(parsed.rows[1].type, TxnType.dividend);
      expect(parsed.rows[1].amount, closeTo(88.8, 1e-6));
    });

    test('正确处理引号包裹的逗号与转义引号', () {
      const content = '账户,标的类型,代码,名称,交易类型,日期,份额,价格,金额,手续费,备注\r\n'
          '默认账户,股票,600519,"贵州茅台, 白酒",买入,2026-01-05,100,10,1000,5,"含,逗号的""备注"""\r\n';
      final parsed = parseTxnCsv(content);
      expect(parsed.errors, isEmpty);
      expect(parsed.rows.length, 1);
      expect(parsed.rows.first.assetName, '贵州茅台, 白酒');
      expect(parsed.rows.first.note, '含,逗号的"备注"');
    });

    test('金额缺失时用 份额×价格 推算', () {
      const content = '账户,标的类型,代码,名称,交易类型,日期,份额,价格,金额,手续费,备注\r\n'
          '默认账户,场外基金,000001,华夏成长,买入,20260105,1000,1.5,,,\r\n';
      final parsed = parseTxnCsv(content);
      expect(parsed.rows.first.amount, closeTo(1500, 1e-6));
    });

    test('错误行被记录并跳过，不影响其他行', () {
      const content = '账户,标的类型,代码,名称,交易类型,日期,份额,价格,金额,手续费,备注\r\n'
          '默认账户,股票,600519,贵州茅台,买入,2026-01-05,100,10,1000,,\r\n'
          '默认账户,股票,600520,坏日期,买入,不是日期,100,10,1000,,\r\n'
          '默认账户,股票,600521,坏类型,转账,2026-01-05,100,10,1000,,\r\n';
      final parsed = parseTxnCsv(content);
      expect(parsed.rows.length, 1);
      expect(parsed.errors.length, 2);
    });
  });

  // ---------------- 行情接口（真实联网） ----------------

  group('行情接口（联网）', () {
    test('批量拉取股票 / ETF / 场外基金行情', () async {
      final svc = MarketService();
      try {
        final assets = [
          Asset(code: '600519', name: '', kind: AssetKind.stock, market: 'SH'),
          Asset(code: '510300', name: '', kind: AssetKind.etf, market: 'SH'),
          Asset(code: '000001', name: '', kind: AssetKind.fund),
        ];
        final quotes = await svc.fetchAll(assets);

        expect(quotes.containsKey('600519'), isTrue,
            reason: '应返回贵州茅台行情');
        expect(quotes['600519']!.price, greaterThan(0));
        expect(quotes['600519']!.name, isNotEmpty);

        expect(quotes.containsKey('510300'), isTrue, reason: '应返回沪深300ETF行情');
        expect(quotes['510300']!.price, greaterThan(0));

        expect(quotes.containsKey('000001'), isTrue, reason: '应返回华夏成长净值');
        expect(quotes['000001']!.price, greaterThan(0));
        expect(quotes['000001']!.priceType, anyOf('nav', 'est'));
      } finally {
        svc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('按代码解析名称', () async {
      final svc = MarketService();
      try {
        final stock = await svc.resolveByCode('600519', AssetKind.stock);
        expect(stock, isNotNull);
        expect(stock!.name, contains('茅台'));

        final fund = await svc.resolveByCode('000001', AssetKind.fund);
        expect(fund, isNotNull);
        expect(fund!.name, isNotEmpty);
      } finally {
        svc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('关键词搜索能返回标的', () async {
      final svc = MarketService();
      try {
        final results = await svc.search('茅台');
        expect(results, isNotEmpty);
        expect(results.any((a) => a.code == '600519'), isTrue);
      } finally {
        svc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ---------------- 完整备份 ----------------

  group('完整备份', () {
    AppBackup sample() => AppBackup(
          exportedAt: DateTime(2026, 9, 14, 10, 30),
          accounts: [Account(id: 1, name: '天天基金', note: '主账户')],
          assets: [
            Asset(
              id: 1,
              code: '000001',
              name: '华夏成长混合',
              kind: AssetKind.fund,
              category: '股票型',
            ),
          ],
          txns: [
            Txn(
              id: 1,
              accountId: 1,
              assetId: 1,
              type: TxnType.buy,
              date: DateTime(2026, 1, 5),
              amount: 1000,
              shares: 800,
              price: 1.25,
              fee: 1.5,
              note: '定投',
            ),
            Txn(
              id: 2,
              accountId: 1,
              assetId: 1,
              type: TxnType.dividend,
              date: DateTime(2026, 6, 5),
              amount: 88.8,
            ),
          ],
          targets: [TargetAlloc(id: 1, key: 'cat:股票型', label: '股票型', ratio: 0.6)],
          cashTxns: [
            CashTxn(
              id: 1,
              accountId: 1,
              type: CashType.deposit,
              amount: 20000,
              date: DateTime(2026, 1, 4),
            ),
            // 买入联动的那条：必须连 srcTxnId 一起活着回来
            CashTxn(
              id: 2,
              accountId: 1,
              type: CashType.invest,
              amount: -1001.5,
              date: DateTime(2026, 1, 5),
              note: '来自买入',
              srcTxnId: 1,
            ),
          ],
          settings: {'threshold': '0.05', 'lastAutoBackupDay': '20260914'},
          watchlist: [
            WatchItem(
              id: 1,
              code: 'sh510300',
              kind: AssetKind.etf,
              name: '沪深300',
              sortOrder: 0,
              pinned: true,
            ),
          ],
          dcaPlans: [
            DcaPlan(
              id: 1,
              accountId: 1,
              assetId: 1,
              amount: 500,
              frequency: DcaFrequency.monthly,
              dayOfPeriod: 8,
              startDate: DateTime(2026, 1, 8),
            ),
          ],
        );

    test('编码后再解码，账户/标的/分类/流水/目标/设置全部保留', () {
      final text = sample().encode();
      expect(text, contains('invest_tracker'));

      final back = AppBackup.decode(text);
      expect(back.version, AppBackup.currentVersion);
      expect(back.exportedAt, DateTime(2026, 9, 14, 10, 30));
      expect(back.accounts.length, 1);
      expect(back.accounts.first.name, '天天基金');
      expect(back.assets.first.category, '股票型');
      expect(back.assets.first.kind, AssetKind.fund);
      expect(back.txns.length, 2);
      expect(back.txns.first.shares, closeTo(800, 1e-9));
      expect(back.txns.first.fee, closeTo(1.5, 1e-9));
      expect(back.txns.first.note, '定投');
      expect(back.txns[1].type, TxnType.dividend);
      expect(back.txns[1].amount, closeTo(88.8, 1e-9));
      expect(back.targets.first.ratio, closeTo(0.6, 1e-9));
      expect(back.settings['threshold'], '0.05');
    });

    test('关注列表与定投计划也在备份里（v3），排序/置顶/周期都保留', () {
      final back = AppBackup.decode(sample().encode());
      expect(back.watchlist.single.code, 'sh510300');
      expect(back.watchlist.single.pinned, true);
      expect(back.watchlist.single.sortOrder, 0);
      expect(back.dcaPlans.single.amount, closeTo(500, 1e-9));
      expect(back.dcaPlans.single.frequency, DcaFrequency.monthly);
      expect(back.dcaPlans.single.assetId, 1);
    });

    test('v2 老备份（没有 watchlist/dcaPlans 字段）仍能解码', () {
      const v2 = '{"app":"invest_tracker","version":2,"exportedAt":1757781252000,'
          '"accounts":[],"assets":[],"txns":[],"cashTxns":[],"targets":[]'
          ',"settings":{"threshold":"0.05"}}';
      final back = AppBackup.decode(v2);
      expect(back.version, 2);
      expect(back.watchlist, isEmpty);
      expect(back.dcaPlans, isEmpty);
    });

    test('当前版本号已升到 3（v3 增加关注列表与定投计划）', () {
      expect(AppBackup.currentVersion, 3);
      expect(sample().encode(), contains('"version": 3'));
    });

    test('现金流水也在备份里，且保留 src_txn_id（恢复后余额才对得上）', () {
      final back = AppBackup.decode(sample().encode());
      expect(back.cashTxns.length, 2);
      expect(back.cashTxns.first.type, CashType.deposit);
      expect(back.cashTxns.first.amount, closeTo(20000, 1e-9));

      final linked = back.cashTxns.firstWhere((c) => c.srcTxnId != null);
      expect(linked.type, CashType.invest);
      expect(linked.amount, closeTo(-1001.5, 1e-9),
          reason: '联动流水要与买入金额 + 手续费一致');
      expect(linked.srcTxnId, 1, reason: '丢了它，现金页就无法识别这条是自动生成的');
      expect(linked.note, '来自买入');
    });

    test('v1 老备份（没有 cashTxns 字段）仍能解码，只是现金为空', () {
      // 手写一份 v1 结构：不含 cashTxns
      const v1 = '{"app":"invest_tracker","version":1,"exportedAt":1757781252000,'
          '"accounts":[{"id":1,"name":"默认账户","note":""}],'
          '"assets":[],"txns":[],"targets":[],"settings":{"threshold":"0.05"}}';
      final back = AppBackup.decode(v1);
      expect(back.version, 1);
      expect(back.cashTxns, isEmpty);
      expect(back.accounts.single.name, '默认账户');
      expect(back.settings['threshold'], '0.05');
    });

    test('当前版本号已升到 2（v1 备份不含现金流水）', () {
      expect(AppBackup.currentVersion, 3);
      expect(sample().encode(), contains('"version": 3'));
    });

    test('统计字段正确', () {
      final b = sample();
      expect(b.accountCount, 1);
      expect(b.usedAssetCount, 1);
      expect(b.txns.length, 2);
    });

    test('拒绝其他应用的 JSON', () {
      expect(
        () => AppBackup.decode('{"app":"something_else","version":1}'),
        throwsA(isA<BackupException>()),
      );
    });

    test('拒绝版本过高的备份', () {
      expect(
        () => AppBackup.decode('{"app":"invest_tracker","version":99}'),
        throwsA(isA<BackupException>()),
      );
    });

    test('拒绝空内容与非法 JSON', () {
      expect(() => AppBackup.decode('   '), throwsA(isA<BackupException>()));
      expect(() => AppBackup.decode('这不是 JSON'), throwsA(isA<BackupException>()));
      expect(() => AppBackup.decode('[1,2,3]'), throwsA(isA<BackupException>()));
    });

    test('缺字段的备份按空处理，不抛异常', () {
      final back = AppBackup.decode('{"app":"invest_tracker","version":1}');
      expect(back.accounts, isEmpty);
      expect(back.txns, isEmpty);
      expect(back.targets, isEmpty);
      expect(back.settings, isEmpty);
      expect(back.watchlist, isEmpty);
      expect(back.dcaPlans, isEmpty);
    });
  });

  // ---------------- 收益口径 ----------------

  group('收益口径（今日/前日 · 持仓收益 · 累计收益）', () {
    final asset =
        Asset(id: 1, code: '510300', name: '沪深300ETF', kind: AssetKind.etf, market: 'SH');
    final assets = {1: asset};

    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    Quote quoteOn(DateTime day, {double price = 12.0, double prev = 10.0, String? dateText}) =>
        Quote(
          code: '510300',
          kind: AssetKind.etf,
          name: '沪深300ETF',
          price: price,
          prevClose: prev,
          changePct: prev > 0 ? (price / prev - 1) * 100 : 0,
          priceType: 'price',
          infoDate: dateText ?? iso(day),
        );

    // 1000 份、成本 10000、单价 10；行情价 12、昨收 10 → 当日收益 (12-10)*1000 = 2000
    List<Txn> oneBuy() => [
          Txn(
            accountId: 1,
            assetId: 1,
            type: TxnType.buy,
            date: DateTime(2026, 8, 1),
            amount: 10000,
            shares: 1000,
            price: 10,
          ),
        ];

    test('标签固定是「当日收益」：行情就是今天也一样', () {
      final p = buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {'510300': quoteOn(DateTime.now())},
      ).first;
      expect(p.isDayPnlToday, isTrue);
      expect(p.dayPnlLabel, '当日收益');
      expect(p.dayPnlLabelWithDate, '当日收益');
      expect(p.dayPnl, closeTo(2000, 1e-9));
    });

    test('行情是上一交易日：标签不变，也不带日期（数值口径不变）', () {
      final prevDay = DateTime.now().subtract(const Duration(days: 3));
      final p = buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {'510300': quoteOn(prevDay)},
      ).first;
      expect(p.isDayPnlToday, isFalse);
      expect(p.dayPnlLabel, '当日收益');
      expect(p.dayPnlLabelWithDate, '当日收益',
          reason: '不再拼成「前日收益 09-11」');
      // 金额仍是最近一个交易日的涨跌
      expect(p.dayPnl, closeTo(2000, 1e-9));
      // 想知道是哪一天就看这个（总览页拿它显示市值更新日期）
      expect(p.dayPnlDay, isNotNull);
    });

    test('行情没有日期信息 → 同样是「当日收益」', () {
      final p = buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {
          '510300': Quote(
              code: '510300', kind: AssetKind.etf, price: 12, prevClose: 10, infoDate: ''),
        },
      ).first;
      expect(p.dayPnlDay, isNull);
      expect(p.dayPnlLabel, '当日收益');
    });

    test('行情日期解析：20260911 与 2026-09-11 15:00 都能识别', () {
      final compact = Quote(code: 'x', kind: AssetKind.etf, infoDate: '2026-09-11');
      expect(compact.tradeDay, DateTime(2026, 9, 11));
      final withTime = Quote(code: 'x', kind: AssetKind.etf, infoDate: '2026-09-11 15:00');
      expect(withTime.tradeDay, DateTime(2026, 9, 11));
      expect(compact.isTradeDayToday(DateTime(2026, 9, 11, 23, 59)), isTrue);
      expect(compact.isTradeDayToday(DateTime(2026, 9, 12)), isFalse);
    });

    test('持仓收益 = 浮动盈亏；累计收益 = 持仓收益 + 已实现收益', () {
      final p = buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {'510300': quoteOn(DateTime.now())},
      ).first;
      expect(p.holdingPnl, closeTo(2000, 1e-9));
      expect(p.holdingPnl, closeTo(p.floating, 1e-9));
      expect(p.realized, closeTo(0, 1e-9));
      expect(p.cumulativePnl, closeTo(2000, 1e-9));
      expect(p.cumulativePnl, closeTo(p.holdingPnl + p.realized, 1e-9));
    });

    test('没有行情时持仓收益率返回 null，而不是冒充 0%', () {
      final p = buildPositions(txns: oneBuy(), assets: assets, quotes: {}).first;
      expect(p.hasQuote, isFalse);
      expect(p.floatingPctOrNull, isNull);
      expect(fmtPctOrNull(p.floatingPctOrNull), '--');
    });

    test('组合汇总的当日收益与标签', () {
      final today = summarize(buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {'510300': quoteOn(DateTime.now())},
      ));
      expect(today.dayPnl, closeTo(2000, 1e-9));
      expect(today.isDayPnlToday, isTrue);
      expect(today.dayPnlLabel, '当日收益');
      expect(today.holdingPnl, closeTo(2000, 1e-9));
      expect(today.cumulativePnl, closeTo(2000, 1e-9));

      final prev = summarize(buildPositions(
        txns: oneBuy(),
        assets: assets,
        quotes: {'510300': quoteOn(DateTime.now().subtract(const Duration(days: 2)))},
      ));
      expect(prev.isDayPnlToday, isFalse);
      expect(prev.dayPnlLabel, '当日收益');
      expect(prev.dayPnlLabelWithDate, '当日收益');
      expect(prev.dayPnlDate, isNotNull);
    });
  });

  // ---------------- 平均成本法不变量 ----------------

  group('平均成本法不变量（卖出后收益率不变）', () {
    final asset =
        Asset(id: 1, code: '600519', name: '贵州茅台', kind: AssetKind.stock, market: 'SH');
    final assets = {1: asset};

    Quote q(double price) => Quote(
          code: '600519',
          kind: AssetKind.stock,
          price: price,
          prevClose: price,
          infoDate: '2026-09-11',
        );

    Txn buy(double amount, double shares, DateTime d) => Txn(
        accountId: 1,
        assetId: 1,
        type: TxnType.buy,
        date: d,
        amount: amount,
        shares: shares,
        price: amount / shares);

    Txn sell(double shares, double price, DateTime d, {double fee = 0}) => Txn(
        accountId: 1,
        assetId: 1,
        type: TxnType.sell,
        date: d,
        amount: shares * price,
        shares: shares,
        price: price,
        fee: fee);

    test('部分卖出后成本单价与持仓收益率都不变', () {
      final base = [
        buy(1000, 100, DateTime(2026, 1, 5)),
        buy(2000, 100, DateTime(2026, 2, 5)),
      ];
      final before =
          buildPositions(txns: base, assets: assets, quotes: {'600519': q(25)}).first;
      expect(before.avgCost, closeTo(15, 1e-9));
      expect(before.holdingPct, closeTo(66.6667, 1e-3));

      final after = buildPositions(
        txns: [...base, sell(100, 30, DateTime(2026, 3, 5), fee: 5)],
        assets: assets,
        quotes: {'600519': q(25)},
      ).first;
      expect(after.avgCost, closeTo(15, 1e-9), reason: '成本单价必须不变');
      expect(after.holdingPct, closeTo(before.holdingPct, 1e-9),
          reason: '持仓收益率必须不变');
      expect(after.shares, closeTo(100, 1e-9));
    });

    test('按市价部分卖出后，持仓收益率与累计收益率都不变', () {
      final base = [buy(1000, 100, DateTime(2026, 1, 5)), buy(2000, 100, DateTime(2026, 2, 5))];
      final before =
          buildPositions(txns: base, assets: assets, quotes: {'600519': q(25)}).first;

      // 卖出价 == 最新价
      final after = buildPositions(
        txns: [...base, sell(100, 25, DateTime(2026, 3, 5))],
        assets: assets,
        quotes: {'600519': q(25)},
      ).first;

      // 持仓收益的「金额」会随份额减少而减少（卖了一半），但「收益率」不变
      expect(after.shares, closeTo(before.shares / 2, 1e-9));
      expect(after.holdingPnl, closeTo(before.holdingPnl / 2, 1e-9));
      expect(after.holdingPct, closeTo(before.holdingPct, 1e-9),
          reason: '持仓收益率必须不变');
      // 累计收益是「建仓以来所有收益」，按市价卖出不产生额外盈亏 → 金额保持不变
      expect(after.cumulativePnl, closeTo(before.cumulativePnl, 1e-9),
          reason: '按市价卖出不产生额外盈亏，累计收益金额应不变');
      expect(after.cumulativePct, closeTo(before.cumulativePct, 1e-9));
    });

    test('低于市价卖出会减少累计收益，高于市价卖出会增加', () {
      final base = [buy(1000, 100, DateTime(2026, 1, 5))];
      final before =
          buildPositions(txns: base, assets: assets, quotes: {'600519': q(12)}).first;
      expect(before.cumulativePnl, closeTo(200, 1e-9)); // 100 份 × (12-10)

      final cheap = buildPositions(
        txns: [...base, sell(50, 9, DateTime(2026, 2, 5))], // 低于市价卖
        assets: assets,
        quotes: {'600519': q(12)},
      ).first;
      expect(cheap.cumulativePnl, lessThan(before.cumulativePnl));

      final dear = buildPositions(
        txns: [...base, sell(50, 15, DateTime(2026, 2, 5))], // 高于市价卖
        assets: assets,
        quotes: {'600519': q(12)},
      ).first;
      expect(dear.cumulativePnl, greaterThan(before.cumulativePnl));
    });

    test('多次买入多次卖出后，成本单价仍等于加权平均', () {
      final txns = [
        buy(1000, 100, DateTime(2026, 1, 1)), // 均价 10
        buy(2000, 100, DateTime(2026, 2, 1)), // 成本 3000 / 200 份 → 15
        sell(50, 22, DateTime(2026, 3, 1)), // 成本 2250 / 150 份 → 15
        buy(1500, 50, DateTime(2026, 4, 1)), // 成本 3750 / 200 份 → 18.75
        sell(20, 18, DateTime(2026, 5, 1)), // 成本 3375 / 180 份 → 18.75
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.shares, closeTo(180, 1e-9));
      expect(p.cost, closeTo(3375, 1e-9));
      expect(p.avgCost, closeTo(18.75, 1e-9));
      expect(p.realized, closeTo(350 - 15, 1e-9));
    });

    test('分红不改变成本单价与持仓收益率', () {
      final base = [buy(1000, 100, DateTime(2026, 1, 5))];
      final before =
          buildPositions(txns: base, assets: assets, quotes: {'600519': q(12)}).first;

      final after = buildPositions(
        txns: [
          ...base,
          Txn(
              accountId: 1,
              assetId: 1,
              type: TxnType.dividend,
              date: DateTime(2026, 6, 5),
              amount: 88),
        ],
        assets: assets,
        quotes: {'600519': q(12)},
      ).first;

      expect(after.avgCost, closeTo(before.avgCost, 1e-9));
      expect(after.holdingPct, closeTo(before.holdingPct, 1e-9));
      expect(after.cumulativePnl, closeTo(before.cumulativePnl + 88, 1e-9));
    });

    test('清仓后重新买入，成本从零重建', () {
      final txns = [
        buy(1000, 100, DateTime(2026, 1, 5)),
        sell(100, 12, DateTime(2026, 3, 5)),
        buy(4000, 200, DateTime(2026, 4, 5)),
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.shares, closeTo(200, 1e-9));
      expect(p.cost, closeTo(4000, 1e-9));
      expect(p.avgCost, closeTo(20, 1e-9));
      expect(p.realized, closeTo(200, 1e-9));
    });

    test('超卖时现金口径自洽，不会出现负净投入', () {
      final txns = [
        buy(1000, 100, DateTime(2026, 1, 5)), // 投入 1000
        sell(200, 10, DateTime(2026, 2, 5)), // 只持有 100 份，却录入卖 200 份
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.shares, 0);
      expect(p.cost, 0);
      expect(p.realized, closeTo(0, 1e-9));
      expect(p.returned, closeTo(1000, 1e-9), reason: '只应计入实际卖出的 100 份');
      expect(p.netInvested, closeTo(0, 1e-9), reason: '净投入不能为负');
    });

    test('成本不会出现负值', () {
      final txns = [
        buy(1000.0, 100, DateTime(2026, 1, 5)),
        sell(33.333333, 12, DateTime(2026, 2, 5)),
        sell(33.333333, 12, DateTime(2026, 3, 5)),
        sell(33.333334, 12, DateTime(2026, 4, 5)),
      ];
      final p = buildPositions(txns: txns, assets: assets, quotes: {}).first;
      expect(p.cost, greaterThanOrEqualTo(0));
      expect(p.shares, greaterThanOrEqualTo(0));
    });
  });
}
