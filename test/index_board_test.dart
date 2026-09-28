import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/index_board.dart';
import 'package:invest_tracker/data/index_eva.dart';

/// 低估榜：分区 / 排序（缺值沉底）/ 成员清单 / 落盘缓存
void main() {
  IndexBoardEntry e(String code, String name,
          {double? pePct,
          double? pbPct,
          double? yeild,
          double? pe,
          String date = '09-28'}) =>
      IndexBoardEntry(
        symbol: 'SH$code',
        code: code,
        name: name,
        v: IndexValuation(
          symbol: 'SH$code',
          name: name,
          pe: pe,
          yeild: yeild,
          pePercentile: pePct,
          pbPercentile: pbPct,
          date: date,
        ),
      );

  IndexBoardEntry missing(String code, String name) =>
      IndexBoardEntry(symbol: 'SH$code', code: code, name: name);

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
        e('000922', '中证红利', yeild: 0.0426),
        e('H30094', '消费红利', yeild: 0.0462),
        e('000300', '沪深300', yeild: 0.0274),
      ];
      expect(sortBoard(rows, BoardSort.dividend).map((r) => r.name),
          ['消费红利', '中证红利', '沪深300']);
      expect(
          sortBoard(rows, BoardSort.dividend, desc: false)
              .map((r) => r.name),
          ['沪深300', '中证红利', '消费红利']);
    });

    test('**缺值的永远沉底**（正序倒序都一样）', () {
      final rows = [
        e('000300', '沪深300', pePct: 0.59),
        missing('1', '没取到的'),
        e('H30094', '消费红利', pePct: 0.08),
      ];
      expect(sortBoard(rows, BoardSort.pePercentile).last.name, '没取到的');
      expect(
          sortBoard(rows, BoardSort.pePercentile, desc: true).last.name,
          '没取到的');
      // 按股息率排时也要沉底（给有值的几条一个股息率）
      final rows2 = [
        e('000300', '沪深300', yeild: 0.0274),
        missing('1', '没取到的'),
        e('H30094', '消费红利', yeild: 0.0462),
      ];
      expect(sortBoard(rows2, BoardSort.dividend).last.name, '没取到的');
    });

    test('按名称排序', () {
      final rows = [e('1', '乙'), e('2', '甲')];
      expect(sortBoard(rows, BoardSort.name).map((r) => r.name), ['乙', '甲']);
      expect(sortBoard(rows, BoardSort.name, desc: true).map((r) => r.name),
          ['甲', '乙']);
    });
  });

  group('成员清单（内置）', () {
    test('35 只、符号合法、无重复', () {
      expect(kIndexBoardSeeds, hasLength(35));
      final symbols = kIndexBoardSeeds.map((e) => e.symbol).toSet();
      expect(symbols, hasLength(35)); // 不能有重的
      for (final s in kIndexBoardSeeds) {
        expect(s.symbol, matches(RegExp(r'^(SH|SZ|CSI)')));
        expect(s.code.trim(), isNotEmpty);
        expect(s.name.trim(), isNotEmpty);
      }
      // 实测过的两个符号要在里面（回归用）
      expect(symbols.contains('SH000922'), isTrue); // 中证红利
      expect(symbols.contains('CSIH30094'), isTrue); // 消费红利（最低估那个）
    });
  });

  group('落盘缓存', () {
    test('写进去再读回来，字段一致', () async {
      final dir = Directory.systemTemp.createTempSync('idx_board');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = IndexBoardStore(dirOf: () async => dir);
      final at = DateTime(2026, 9, 29, 21, 30);
      await store.save([
        e('H30094', '消费红利', pePct: 0.0816, yeild: 0.0462, pe: 18.94),
        missing('399975', '证券公司'),
      ], at);
      final got = await store.load();
      expect(got, isNotNull);
      final (rows, savedAt) = got!;
      expect(savedAt, at);
      expect(rows, hasLength(2));
      final r = rows.firstWhere((x) => x.code == 'H30094');
      expect(r.name, '消费红利');
      expect(r.pePct, closeTo(0.0816, 1e-9));
      expect(r.dividend, closeTo(0.0462, 1e-9));
      expect(r.v?.symbol, 'SHH30094');
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
  });
}
