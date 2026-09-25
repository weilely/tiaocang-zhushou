import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/update_source.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/update_page.dart';
import 'package:provider/provider.dart';

/// 「更新」页面：进页面要把**更新条目**摊开（版本号 + 日期 + 发行说明）
///
/// 只显示比当前版本新的那些；不比当前新的（包括当前这版）不列出来。
void main() {
  UpdateInfo info(String v, {String? notes, String? apk, DateTime? at}) =>
      UpdateInfo(
        latest: v,
        url: 'https://example.com/releases',
        source: 'Gitee',
        notes: notes,
        apkUrl: apk,
        publishedAt: at,
      );

  Future<void> pumpPage(WidgetTester tester, UpdateCheck check) async {
    final st = AppState()
      ..loading = false
      ..updateCheck = check
      ..knownLatestVersion = check.newest.latest;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        child: const MaterialApp(home: UpdatePage()),
      ),
    );
    // 只泵一帧：进页面会顺带联网强制查一次（测试环境里必然失败），
    // 用 pumpAndSettle 会等那个超时
    await tester.pump();
  }

  testWidgets('列出比当前版本新的每一版，带版本号/日期/说明', (tester) async {
    final newest = info('9.9.9', notes: '最新一版：修了几个 bug');
    await pumpPage(tester, (
      newest: newest,
      installable: null,
      releases: [
        info('9.9.9', notes: '最新一版：修了几个 bug', at: DateTime(2026, 9, 25)),
        info('9.9.8', notes: '上一版：加了更新页面', at: DateTime(2026, 9, 20)),
        info('1.0.0', notes: '远古版本，不该出现'),
      ],
    ));
    await tester.pump();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('v9.9.9'), findsOneWidget);
    expect(find.text('v9.9.8'), findsOneWidget);
    expect(find.textContaining('最新一版'), findsOneWidget);
    expect(find.textContaining('加了更新页面'), findsOneWidget);
    expect(find.textContaining('不该出现'), findsNothing,
        reason: '不比当前版本新的条目不该列出来');
    expect(find.textContaining('2026-09-25'), findsOneWidget);
  });

  testWidgets('已是最新：说明没有更新条目可看', (tester) async {
    await pumpPage(tester, (
      newest: info('1.0.0'),
      installable: null,
      releases: [info('1.0.0')],
    ));
    await tester.pump();

    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.textContaining('没有需要看的更新条目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最新版没安装包 → 给复制发布页链接，而不是下载按钮', (tester) async {
    await pumpPage(tester, (
      newest: info('9.9.9', notes: 'x'),
      installable: null,
      releases: [info('9.9.9', notes: 'x')],
    ));
    await tester.pump();

    expect(find.text('复制发布页链接'), findsOneWidget);
    expect(find.textContaining('没有适配你机型的安装包'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('这一版有适配本机的包 → 给「下载并安装」', (tester) async {
    await pumpPage(tester, (
      newest: info('9.9.9', notes: 'x'),
      installable: info('9.9.9', notes: 'x', apk: 'https://e/x-arm64-v8a.apk'),
      releases: [info('9.9.9', notes: 'x')],
    ));
    await tester.pump();

    expect(find.textContaining('下载并安装 v9.9.9'), findsOneWidget);
    expect(find.textContaining('同签名'), findsOneWidget);
  });
}
