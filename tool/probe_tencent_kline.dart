// 探针：腾讯日K（东财备胎）真机网络下能拿多少历史
// 用法：dart run tool/probe_tencent_kline.dart
//
// ignore_for_file: avoid_print
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_source.dart';

Future<void> main() async {
  final src = NavSource();
  for (final code in ['sh000300', 'sh000001', 'sz399006']) {
    final a = Asset(code: code, name: code, kind: AssetKind.other);
    try {
      final t0 = DateTime.now();
      final pts = await src.tencentKline(a, beg: '20050101', end: '20100101');
      final ms = DateTime.now().difference(t0).inMilliseconds;
      print('$code 东财口径2010前: ${pts.length} 条 '
          '最早=${pts.isEmpty ? "-" : pts.first.date} '
          '最新=${pts.isEmpty ? "-" : pts.last.date} (${ms}ms)');
      final full = await src.tencentKline(a);
      print('$code 默认(往回2000): ${full.length} 条 '
          '最早=${full.isEmpty ? "-" : full.first.date} '
          '最新=${full.isEmpty ? "-" : full.last.date}');
    } catch (e) {
      print('$code 失败: $e');
    }
  }
  src.dispose();
}
