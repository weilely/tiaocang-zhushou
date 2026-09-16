import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/ui/widgets/segmented_pills.dart';

/// 分段控件与筹码组：对齐 `pic/23.jpg`、`pic/24.jpg` 的「灰容器 + 白底蓝字胶囊」
///
/// 旧样式是蓝色**描边框**，这里用「选中项是否为白底胶囊」把它和旧样式区分开。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  /// 取某个标签最近的 Material（就是胶囊本体）
  Material pillOf(WidgetTester tester, String label) => tester.widget<Material>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Material))
            .first,
      );

  Color cardColor(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold))).cardColor;

  group('SegmentedPills', () {
    testWidgets('只给选中项上白底胶囊，未选中项透明', (tester) async {
      var selected = 1;
      await tester.pumpWidget(host(
        StatefulBuilder(
          builder: (context, setState) => SegmentedPills<int>(
            selected: selected,
            onChanged: (v) => setState(() => selected = v),
            items: const [
              (value: 0, label: '日收益'),
              (value: 1, label: '月收益'),
              (value: 2, label: '年收益'),
            ],
          ),
        ),
      ));

      expect(pillOf(tester, '月收益').color, cardColor(tester));
      expect(pillOf(tester, '日收益').color, Colors.transparent);
      expect(pillOf(tester, '年收益').color, Colors.transparent);
    });

    testWidgets('点未选中项会切换胶囊', (tester) async {
      var selected = 0;
      await tester.pumpWidget(host(
        StatefulBuilder(
          builder: (context, setState) => SegmentedPills<int>(
            selected: selected,
            onChanged: (v) => setState(() => selected = v),
            items: const [
              (value: 0, label: '日历图'),
              (value: 1, label: '趋势图'),
            ],
          ),
        ),
      ));

      await tester.tap(find.text('趋势图'));
      await tester.pumpAndSettle();

      expect(pillOf(tester, '趋势图').color, cardColor(tester));
      expect(pillOf(tester, '日历图').color, Colors.transparent);
    });

    testWidgets('选中项文字用主色，未选中用提示色', (tester) async {
      await tester.pumpWidget(host(
        SegmentedPills<int>(
          selected: 0,
          onChanged: (_) {},
          items: const [
            (value: 0, label: '甲'),
            (value: 1, label: '乙'),
          ],
        ),
      ));
      final theme = Theme.of(tester.element(find.byType(SegmentedPills<int>)));
      expect(tester.widget<Text>(find.text('甲')).style?.color,
          theme.colorScheme.primary);
      expect(tester.widget<Text>(find.text('乙')).style?.color, theme.hintColor);
    });

    testWidgets('expand=false 时容器贴合内容宽度', (tester) async {
      await tester.pumpWidget(host(
        SegmentedPills<int>(
          expand: false,
          selected: 0,
          onChanged: (_) {},
          items: const [
            (value: 0, label: '日历图'),
            (value: 1, label: '趋势图'),
          ],
        ),
      ));
      final box = tester.getSize(find.byType(SegmentedPills<int>));
      expect(box.width, lessThan(300), reason: '贴合内容，不该占满整行');
    });

    testWidgets('整段可点（点文字左侧的空白也应生效）', (tester) async {
      var picked = -1;
      await tester.pumpWidget(host(
        SegmentedPills<int>(
          selected: 0,
          onChanged: (v) => picked = v,
          items: const [
            (value: 0, label: '日收益'),
            (value: 1, label: '月收益'),
          ],
        ),
      ));
      // 点「月收益」所在胶囊的左边缘附近，而不是文字正中
      final rect = tester.getRect(find.text('月收益'));
      await tester.tapAt(Offset(rect.left - 4, rect.center.dy));
      expect(picked, 1);
    });
  });

  group('PillGroup', () {
    testWidgets('所有筹码在同一个容器里，选中项白胶囊、未选中无边框', (tester) async {
      await tester.pumpWidget(host(
        PillGroup(items: [
          (label: '当月', selected: true, onTap: () {}),
          (label: '近3月', selected: false, onTap: () {}),
          (label: '更多', selected: false, onTap: () {}),
        ]),
      ));

      expect(pillOf(tester, '当月').color, cardColor(tester));
      expect(pillOf(tester, '近3月').color, Colors.transparent);
      // 未选中的筹码不再是各自带边框的胶囊
      final track = tester.widget<Container>(
        find
            .descendant(
                of: find.byType(PillGroup), matching: find.byType(Container))
            .first,
      );
      expect((track.decoration as BoxDecoration).border, isNull);
    });

    testWidgets('点筹码触发对应回调', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(host(
        PillGroup(items: [
          (label: '当月', selected: true, onTap: () => tapped.add('当月')),
          (label: '今年', selected: false, onTap: () => tapped.add('今年')),
        ]),
      ));
      await tester.tap(find.text('今年'));
      expect(tapped, ['今年']);
    });
  });

  group('SquareIconButton', () {
    testWidgets('是圆角方形浅灰按钮，禁用时不响应', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(host(
        SquareIconButton(
          icon: Icons.chevron_left,
          tooltip: '上个月',
          onPressed: () => tapped++,
        ),
      ));
      final size = tester.getSize(find.byType(SquareIconButton));
      expect(size.width, size.height, reason: '应当是正方形');
      await tester.tap(find.byType(SquareIconButton));
      expect(tapped, 1);

      await tester.pumpWidget(host(
        const SquareIconButton(
          icon: Icons.chevron_left,
          tooltip: '上个月',
          onPressed: null,
        ),
      ));
      await tester.tap(find.byType(SquareIconButton));
      expect(tapped, 1, reason: '禁用状态不该回调');
    });
  });
}
