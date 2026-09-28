import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_pe_hist.dart';
import 'package:invest_tracker/data/index_board.dart';

/// 低估榜数据层：分区 / 排序（缺值沉底）/ 成员（两批）/ 自算行 / 落盘缓存
void main() {
  IndexBoardEntry e(String code, String name,
          {double? pePct,
          double? pbPct,
          double? dividend,
          double? pe,
          String kind = '宽基',
          String symbol = 'SHx'}) =>
      IndexBoardEntry(
        code: code,
        name: name,
        kind: kind,
        symbol: symbol,
        ok: true,
        pe: pe,
        pePct: pePct,
        pbPct: pbPct,
        dividend: dividend,
        date: '09-28',
      );

  IndexBoardEntry missing(String code, String name) =>
      IndexBoardEntry(code: code, name: name, kind: '宽基', symbol: 'SHx');

  group('低估 / 适中 / 高估（按 PE 分位划）', () {
    test('低于 30% 低估、高于 70% 高估、中间适中', () {
      expect(e('1', 'a', pePct: 0.0).zone, '低估');
      expect(e('1', 'a', pePct: 0.0816).zone, '低估');
      expect(e('1', 'a', pePct: 0.2999).zone, '低估');
      expect(e('1', 'a', pePct: 0.30).zone, '适中');
      expect(e('1', 'a', pePct: 0.70).zone, '适中');
      expect(e('1', 'a', pePct: 0.7001).zone, '高估');
      expect(e('1', 'a', pePct: 0.9696).zone, '高估');
    });

    test('没有分位就不给标签（别瞎标成低估）', () {
      expect(e('1', 'a').zone, '');
      expect(missing('1', 'a').zone, '');
      expect(missing('1', 'a').missing, isTrue);
    });
  });

  group('排序', () {
    test('默认按 PE 分位从小到大（低估在前）', () {
      final rows = [
        e('399975', '中证红利', pePct: 0.79),
        e('H30094', '消费红利', pePct: 0.08),
        e('000015', '红利指数', pePct: 0.97),
      ];
      expect(sortBoard(rows, BoardSort.pePercentile).map((r) => r.name),
          ['消费红利', '中证红利', '红利指数']);
    });

    test('换字段：股息率默认从大到小', () {
      final rows = [
        e('000922', '中证红利', dividend: 0.0426),
        e('H30094', '消费红利', dividend: 0.0462),
        e('000300', '沪深300', dividend: 0.0274),
      ];
      expect(sortBoard(rows, BoardSort.dividend).map((r) => r.name),
          ['消费红利', '中证红利', '沪深300']);
      expect(sortBoard(rows, BoardSort.dividend, desc: false).map((r) => r.name),
          ['沪深300', '中证红利', '消费红利']);
    });

    test('**缺值的永远沉底**（正序倒序都一样）', () {
      final rows = [
        e('000300', '沪深300', pePct: 0.59, dividend: 0.0274),
        missing('1', '没取到的'),
        e('H30094', '消费红利', pePct: 0.08, dividend: 0.0462),
      ];
      expect(sortBoard(rows, BoardSort.pePercentile).last.name, '没取到的');
      expect(
          sortBoard(rows, BoardSort.pePercentile, desc: true).last.name, '没取到的');
      expect(sortBoard(rows, BoardSort.dividend).last.name, '没取到的');
    });

    test('按名称排序', () {
      final rows = [e('1', '乙'), e('2', '甲')];
      expect(sortBoard(rows, BoardSort.name).map((r) => r.name), ['乙', '甲']);
      expect(sortBoard(rows, BoardSort.name, desc: true).map((r) => r.name),
          ['甲', '乙']);
    });
  });

  group('成员（两批：蛋卷 + 中证自算）', () {
    test('总数 = 蛋卷 35 + 自算 9，代码不重复、分类都在三档里', () {
      expect(kIndexBoardSeeds, hasLength(44));
      expect(kBoardDanjuanCount, 35);
      expect(kBoardComputedCount, 9);
      final codes = kIndexBoardSeeds.map((e) => e.code).toSet();
      expect(codes, hasLength(44));
      for (final s in kIndexBoardSeeds) {
        expect(s.code.trim(), isNotEmpty);
        expect(s.name.trim(), isNotEmpty);
        expect(kBoardKinds.contains(s.kind), isTrue,
            reason: '${s.name} 的分类 ${s.kind} 不在 $kBoardKinds 里');
        if (s.symbol.isNotEmpty) {
          expect(s.symbol, matches(RegExp(r'^(SH|SZ|CSI)')));
        }
      }
    });

    test('用户要的"红利/宽基"两类都够用，且几个熟悉的指数在对应类里', () {
      final byName = {for (final s in kIndexBoardSeeds) s.name: s.kind};
      expect(byName['中证红利'], '红利');
      expect(byName['红利低波'], '红利');
      expect(byName['红利质量'], '红利'); // 中证自算那批
      expect(byName['沪深300'], '宽基');
      expect(byName['中证A500'], '宽基'); // 中证自算那批
      expect(byName['中证白酒'], '行业主题');
      expect(kIndexBoardSeeds.where((s) => s.kind == '红利').length, 8);
    });
  });

  group('自算行（中证 PE 历史 → 分位）', () {
    test('有数据时带来源标记、只填得到 PE 与分位', () {
      const seed = (symbol: '', code: '930050', name: '中证A50', kind: '宽基');
      final row = entryFromPeStat(
          seed,
          const CsiPeStat(
              pe: 15.33,
              percentile: 0.1116,
              date: '20260928',
              windowStart: '20231228',
              samples: 717));
      expect(row.ok, isTrue);
      expect(row.source, '中证自算');
      expect(row.zone, '低估');
      expect(row.pe, closeTo(15.33, 1e-9));
      expect(row.pePct, closeTo(0.1116, 1e-9));
      expect(row.dividend, isNull); // 这一路没有股息率
      expect(row.windowStart, '20231228');
      expect(row.samples, 717);
    });

    test('取不到就是"没取到"，不是 0', () {
      const seed = (symbol: '', code: '399001', name: '深证成指', kind: '宽基');
      final row = entryFromPeStat(seed, null);
      expect(row.missing, isTrue);
      expect(row.pe, isNull);
      expect(row.zone, '');
    });
  });

  group('落盘缓存', () {
    test('写进去再读回来（两个时间戳分开存）', () async {
      final dir = Directory.systemTemp.createTempSync('idx_board');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = IndexBoardStore(dirOf: () async => dir);
      final dj = DateTime(2026, 9, 29, 21, 30);
      final csi = DateTime(2026, 9, 20, 8);
      await store.save([
        e('H30094', '消费红利', pePct: 0.0816, dividend: 0.0462, pe: 18.94),
        entryFromPeStat(
            const (symbol: '', code: '930050', name: '中证A50', kind: '宽基'),
            const CsiPeStat(
                pe: 15.33,
                percentile: 0.1116,
                date: '20260928',
                windowStart: '20231228',
                samples: 717)),
        missing('399975', '证券公司'),
      ], danjuanAt: dj, computedAt: csi);

      final got = await store.load();
      expect(got, isNotNull);
      final (rows, danjuanAt, computedAt) = got!;
      expect(danjuanAt, dj);
      expect(computedAt, csi);
      expect(rows, hasLength(3));
      final r = rows.firstWhere((x) => x.code == 'H30094');
      expect(r.name, '消费红利');
      expect(r.pePct, closeTo(0.0816, 1e-9));
      expect(r.dividend, closeTo(0.0462, 1e-9));
      expect(r.source, '蛋卷');
      final a50 = rows.firstWhere((x) => x.code == '930050');
      expect(a50.source, '中证自算');
      expect(a50.samples, 717);
      expect(a50.windowStart, '20231228');
      expect(rows.firstWhere((x) => x.code == '399975').missing, isTrue);
    });

    test('没有缓存 / 缓存坏了 → null，不抛', () async {
      final dir = Directory.systemTemp.createTempSync('idx_board_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = IndexBoardStore(dirOf: () async => dir);
      expect(await store.load(), isNull);
      File('${dir.path}${Platform.pathSeparator}index_board.json')
          .writeAsStringSync('{ 坏文件');
      expect(await store.load(), isNull);
    });

    test('**上一版的老缓存要被拒掉**（结构变了，否则会被读成"全都没取到"还 12 小时不刷）',
        () async {
      final dir = Directory.systemTemp.createTempSync('idx_board_old');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 老结构：没有 v、行里是嵌套的 v（IndexValuation）
      File('${dir.path}${Platform.pathSeparator}index_board.json').writeAsStringSync(
          '{"fetchedAt":"2026-09-29T10:00:00.000","rows":'
          '[{"symbol":"SH000922","code":"000922","name":"中证红利",'
          '"v":{"name":"中证红利","pe":8.6,"pe_percentile":0.79}}]}');
      final store = IndexBoardStore(dirOf: () async => dir);
      expect(await store.load(), isNull); // → AppState 会重新拉
    });
  });
}
