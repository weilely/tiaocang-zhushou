// 探针（纯 Dart，不上设备）：验证「指数走东财全量日线」这条通道。
//
// 背景：新浪日K 的 datalen 上限 1500（约 6 年），沪深300 因此只有 2020-07-20 起，
// 与股债利差（2016-08 起）对不齐。用户 2026-09-29 问「有没有更多的数据源，最好对齐」。
//
// 跑法：E:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool\probe_east_kline.dart
import 'dart:io';

import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_source.dart';

Future<void> main() async {
  final src = NavSource();
  final a = Asset(code: 'sh000300', name: '沪深300', kind: AssetKind.other);

  final pts = await src.eastKline(a);
  stdout.writeln('东财日K：${pts.length} 条');
  if (pts.isNotEmpty) {
    stdout.writeln('  最早 ${pts.first.date} ${pts.first.nav}');
    stdout.writeln('  最新 ${pts.last.date} ${pts.last.nav}');
    final hit = pts.where((p) => p.date == '2016-08-15');
    stdout.writeln('  2016-08-15（股债利差起点）：${hit.isEmpty ? '没有' : hit.first.nav}');
  }

  final sina = await src.sinaDaily(a, datalen: 1500);
  stdout.writeln('新浪日K（上限 1500）：${sina.length} 条'
      '${sina.isEmpty ? '' : '，最早 ${sina.first.date}'}');
}
