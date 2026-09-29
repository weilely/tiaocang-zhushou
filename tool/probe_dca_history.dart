// 探针：定投补记取历史净值时，lsjz 接口在"跨度很大"时到底给多少条
//
// 背景（用户 2026-09-30）：「我就想通过定投生成历史记录，结果不管用」——
// 补记的取价窗口是 [首期待补期 - 10 天, 今天]，接口请求写死
// `pageIndex=1&pageSize=200`。若计划起始日很早（想补两年历史），
// 最早那批期数可能整批落在返回的 200 条之外 → 取不到价 → 一期都补不出来。
//
// 用法：dart run tool/probe_dca_history.dart
//
// ignore_for_file: avoid_print
import 'package:invest_tracker/data/dca_models.dart';
import 'package:invest_tracker/data/dca_source.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/logic/dca.dart';

Future<void> main() async {
  final src = DcaPriceSource();
  final today = DateTime.now();
  final cases = <String, ({String code, AssetKind kind})>{
    '场外基金 021362': (code: '021362', kind: AssetKind.fund),
    '场外基金 004814': (code: '004814', kind: AssetKind.fund),
  };

  for (final e in cases.entries) {
    final a = Asset(code: e.value.code, name: e.key, kind: e.value.kind);
    for (final years in [0, 1, 2, 3]) {
      final from = today.subtract(Duration(days: 365 * years + 10));
      try {
        final m = await src.historyFor(a, from, today);
        final dates = m.keys.toList()..sort();
        print('${e.key}  窗口 ${dayKey(from)} ~ ${dayKey(today)}'
            '  → ${m.length} 条'
            '${dates.isEmpty ? '' : '，最早 ${dates.first}，最新 ${dates.last}'}');
      } catch (err) {
        print('${e.key}  窗口 ${dayKey(from)} ~ ${dayKey(today)}  → 失败：$err');
      }
    }
  }

  // 月定投：从两年前开始，最早 24 期分别落在哪一天（看它们是否会被 200 条截掉）
  final plan = DcaPlan(
    accountId: 1,
    assetId: 1,
    amount: 100,
    frequency: DcaFrequency.monthly,
    dayOfPeriod: 1,
    startDate: today.subtract(const Duration(days: 730)),
  );
  final due = pendingDcaDates(plan: plan, today: today);
  print('月定投（两年前起）最早一批待补 ${due.length} 期：'
      '${due.isEmpty ? '-' : '${dayKey(due.first)} ~ ${dayKey(due.last)}'}');

  final daily = plan.copyWith(
      frequency: DcaFrequency.daily, startDate: today.subtract(const Duration(days: 730)));
  final dueDaily = pendingDcaDates(plan: daily, today: today, maxNew: 31);
  print('日定投（两年前起）最早一批待补 ${dueDaily.length} 期：'
      '${dueDaily.isEmpty ? '-' : '${dayKey(dueDaily.first)} ~ ${dayKey(dueDaily.last)}'}');

  src.dispose();
}
