import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/period_return.dart';
import 'package:invest_tracker/ui/widgets/return_table.dart';

/// 关注表：净值列带日期、代码名称左对齐
void main() {
  WatchItem item(String code, String name) => WatchItem(
        code: code,
        kind: AssetKind.fund,
        name: name,
      );

  /// 造一行：净值 + 净值日期 + 各区间收益
  WatchRow row(
    String code,
    String name, {
    double? nav,
    String? navDate,
  }) {
    final rets = <String, double?>{};
    for (final p in tablePeriods) {
      rets[p.name] = 1.5;
    }
    return WatchRow(
      item: item(code, name),
      nav: nav,
      navDate: navDate,
      returns: rets,
    );
  }

  Widget host(List<WatchRow> rows) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ReturnTable(rows: rows),
          ),
        ),
      );

  group('净值列显示日期', () {
    testWidgets('净值在上、MM-dd 日期在下', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '易方达国证价值100ETF联接发起式A',
            nav: 1.2345, navDate: '2026-09-11'),
      ]));

      expect(find.text('1.2345'), findsOneWidget);
      expect(find.text('09-11'), findsOneWidget, reason: '净值下方要有 MM-dd 日期');

      // 日期必须在净值**下方**
      final navY = tester.getTopLeft(find.text('1.2345')).dy;
      final dateY = tester.getTopLeft(find.text('09-11')).dy;
      expect(dateY, greaterThan(navY));

      // 两者在同一列内水平居中对齐
      final navX = tester.getCenter(find.text('1.2345')).dx;
      final dateX = tester.getCenter(find.text('09-11')).dx;
      expect((navX - dateX).abs(), lessThan(1.5),
          reason: '日期应与净值同列居中');
    });

    testWidgets('没有净值数据时只显示 --，不显示空日期行', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '某基金', nav: null, navDate: null),
      ]));

      expect(find.text('--'), findsOneWidget);
      // 不该出现任何看起来像日期的文本
      expect(find.textContaining(RegExp(r'^\d{2}-\d{2}$')), findsNothing);
    });

    testWidgets('日期解析不了时也不渲染日期行', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '某基金', nav: 1.0, navDate: 'bad-date'),
      ]));
      expect(find.text('1.0000'), findsOneWidget);
      expect(find.textContaining('bad'), findsNothing);
    });

    testWidgets('多行各自显示自己的日期', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '基金A', nav: 1.2345, navDate: '2026-09-11'),
        row('510300', '基金B', nav: 4.5790, navDate: '2026-09-14'),
      ]));

      expect(find.text('09-11'), findsOneWidget);
      expect(find.text('09-14'), findsOneWidget);
      expect(find.text('1.2345'), findsOneWidget);
      expect(find.text('4.5790'), findsOneWidget);
    });
  });

  group('代码名称左对齐', () {
    // 首列用的是 Text.rich；按文本内容定位，避免误抓到数值列的 RichText
    Finder richWith(String text) => find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains(text),
          description: 'RichText containing "$text"',
        );

    testWidgets('表头与数据的左边缘对齐', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '易方达国证价值100ETF联接发起式A',
            nav: 1.0, navDate: '2026-09-11'),
      ]));

      final headerLeft = tester.getTopLeft(find.text('代码名称')).dx;
      final dataLeft = tester.getTopLeft(richWith('025497')).dx;

      expect((headerLeft - dataLeft).abs(), lessThan(2.0),
          reason: '表头「代码名称」($headerLeft) 应与数据 ($dataLeft) 左边缘对齐');
    });

    testWidgets('名称长短不一时数据左边缘一致（左对齐的直接证据）', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '短名A', nav: 1.0, navDate: '2026-09-11'),
        row('021362', '一个特别特别长的基金名称用于测试换行行为AAAA',
            nav: 2.0, navDate: '2026-09-11'),
      ]));

      final leftA = tester.getTopLeft(richWith('025497')).dx;
      final leftB = tester.getTopLeft(richWith('021362')).dx;

      expect((leftA - leftB).abs(), lessThan(1.0),
          reason: '左对齐时不同长度的名称左边缘必须一致，实际 [$leftA, $leftB]');
    });

    testWidgets('区间收益列仍保持居中', (tester) async {
      await tester.pumpWidget(host([
        row('025497', '某基金', nav: 1.0, navDate: '2026-09-11'),
      ]));

      // 「近1周」表头与它的数据（+1.50%）中心应基本重合
      final headerCenter = tester.getCenter(find.text('近1周')).dx;
      final dataCenter = tester.getCenter(find.text('+1.50%').first).dx;
      expect((headerCenter - dataCenter).abs(), lessThan(2.0),
          reason: '数值列应保持表头与数据居中对齐');
    });
  });
}
