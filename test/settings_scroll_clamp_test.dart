import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/settings_page.dart';
import 'package:provider/provider.dart';

/// 设置页滚动位置：内容变短后不许停在 maxScrollExtent 之外
///
/// 用户报的「展开卡片、把标图滚出屏幕，就滚回不去了」「点收起屏闪，只看见检查更新」
/// 是同一个毛病：列表内容变短时 Flutter **不会**把滚动位置夹回范围内，位置会停在
/// 新的 maxScrollExtent **之外**。画面看着停在底部，手指往下拖只是在倒退那段看不见
/// 的超出量，一动不动 —— 于是"滚不回去"。
///
/// 设备实测：`pixels=1240` 而 `maxScrollExtent=437`，差值 803 正好是那张卡片收起的高度。
void main() {
  Future<ScrollPosition> pumpPage(WidgetTester tester, AppState st) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
    final lv = tester.widget<ListView>(find.byType(ListView).first);
    return lv.controller!.position;
  }

  testWidgets('账户变少、内容变短后，滚动位置被夹回范围内（下拖能滚回去）', (tester) async {
    final st = AppState()..loading = false;
    st.accounts = List.generate(20, (i) => Account(id: i + 1, name: '账户${i + 1}'));
    final pos = await pumpPage(tester, st);

    // 停在底部
    final maxBefore = pos.maxScrollExtent;
    pos.jumpTo(maxBefore);
    await tester.pump();
    expect(pos.pixels, greaterThan(0), reason: '前提：页面得先能滚起来');

    // 内容缩水：账户清空 → 「账户管理」卡片变矮
    st.accounts = [];
    st.notifyListeners();
    await tester.pumpAndSettle();

    expect(pos.maxScrollExtent, lessThan(maxBefore), reason: '前提：账户清空后内容确实变短');
    expect(pos.pixels, lessThanOrEqualTo(pos.maxScrollExtent + 0.5),
        reason: '内容变短后滚动位置必须夹回 maxScrollExtent 之内，否则就是「滚不回去」');

    // 夹回来之后，往下拖必须真的能滚（用户在意的就是这个）
    final before = pos.pixels;
    await tester.drag(find.byType(ListView).first, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(pos.pixels, lessThan(before), reason: '位置有效时，往下拖应该把列表往回滚');
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容没变时不做任何多余动作（位置原地不动）', (tester) async {
    final st = AppState()..loading = false;
    st.accounts = List.generate(20, (i) => Account(id: i + 1, name: '账户${i + 1}'));
    final pos = await pumpPage(tester, st);

    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    final at = pos.pixels;

    st.notifyListeners();
    await tester.pumpAndSettle();
    expect(pos.pixels, closeTo(at, 0.5), reason: '内容没变就不该动位置');
    expect(tester.takeException(), isNull);
  });
}
