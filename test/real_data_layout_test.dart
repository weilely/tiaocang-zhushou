import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/asset_traits.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/backup.dart';
import 'package:invest_tracker/logic/cash_flow.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/all_txns_page.dart';
import 'package:invest_tracker/ui/cash_manage_page.dart';
import 'package:invest_tracker/ui/holdings_page.dart';
import 'package:invest_tracker/ui/txn_edit_page.dart';
import 'package:provider/provider.dart';

/// **真数据布局体检**：不建 APK、不连模拟器，十几秒把最容易挤爆的几个界面
/// 按真机参数（400dp 宽 + 字体 1.3）渲染一遍。
///
/// 为什么要有它：真机专属的坑（窄屏 + 大字体挤爆、宽度阈值把东西藏起来）
/// 用默认配置的模拟器验不出来，而每次为看一眼都构建一遍 APK 要 3~4 分钟。
/// 数据直接读他库里的全局备份 JSON —— **文件放在仓库外**（公开仓库里绝不能有
/// 他的真实数据），文件不在（换机器 / 清过）就整组跳过，所以用例可以留在仓库里。
///
/// 跑法：`flutter test test/real_data_layout_test.dart`
const String _backupPath = r'E:\DSH\_dbbackup\全局备份_20260928_v9.json';

void main() {
  final file = File(_backupPath);
  if (!file.existsSync()) {
    test('真数据布局体检', () {
      markTestSkipped('没有备份文件：$_backupPath');
    });
    return;
  }

  final back = AppBackup.decode(file.readAsStringSync());

  /// 用手工注入的方式拼一个 AppState（测试里没有 sqflite）——
  /// 数据全是他库里的真东西，界面上的名字/金额/份额都是真的。
  AppState makeState() {
    final st = AppState()..loading = false;
    st.accounts = back.accounts;
    st.assetList = back.assets;
    st.assetsById = {for (final a in back.assets) if (a.id != null) a.id!: a};
    st.txns = back.txns;
    st.cashTxns = back.cashTxns;
    // 简称 / 费率 / 分红方式都在备份的 settings 里
    for (final e in back.settings.entries) {
      if (e.key.startsWith('assetShort:')) {
        final v = e.value.trim();
        if (v.isNotEmpty) st.assetShorts[e.key.substring('assetShort:'.length)] = v;
      } else if (e.key.startsWith('feeRate:')) {
        final id = int.tryParse(e.key.substring('feeRate:'.length));
        final v = double.tryParse(e.value);
        if (id != null && v != null) st.feeRates[id] = v;
      } else if (e.key.startsWith('feeWaiveMin:')) {
        final id = int.tryParse(e.key.substring('feeWaiveMin:'.length));
        if (id != null && e.value == '1') st.feeWaiveMin.add(id);
      } else if (e.key.startsWith('subFeeRate:')) {
        final v = double.tryParse(e.value);
        if (v != null) st.subFeeRates[e.key.substring('subFeeRate:'.length)] = v;
      } else if (e.key.startsWith('redeemFeeRate:')) {
        final v = double.tryParse(e.value);
        if (v != null) st.redeemFeeRates[e.key.substring('redeemFeeRate:'.length)] = v;
      }
    }
    // 现金余额/收益是派生值：直接按同一套纯函数算（备份里不含它们）
    final balances = <int, double>{};
    for (final c in back.cashTxns) {
      balances[c.accountId] = (balances[c.accountId] ?? 0) + c.amount;
    }
    st.cashBalances = balances;
    st.cashIncome = cashIncomeOf(back.cashTxns);
    // 行情：备份里**不含** quotes（可重抓），用历史净值最后一条合成，
    // 这样卡片上的市值/收益是真数，不是 `--`。
    final navs = <String, List<NavPoint>>{};
    for (final row in back.navHistory) {
      final p = NavPoint.fromMap(row);
      if (p.code.isEmpty || p.nav <= 0) continue;
      (navs[p.code] ??= <NavPoint>[]).add(p);
    }
    for (final l in navs.values) {
      l.sort((a, b) => a.date.compareTo(b.date));
    }
    st.navSamples = navs;
    final quotes = <String, Quote>{};
    for (final a in back.assets) {
      final l = navs[a.code];
      if (l == null || l.isEmpty) continue;
      final last = l.last;
      final prev = l.length > 1 ? l[l.length - 2] : null;
      quotes[a.code] = Quote(
        code: a.code,
        kind: a.kind,
        name: a.name,
        price: last.nav,
        prevClose: prev?.nav ?? last.nav,
        changePct: prev == null || prev.nav == 0
            ? 0
            : (last.nav / prev.nav - 1) * 100,
        priceType: a.kind.traits.priceIsLive ? 'price' : 'nav',
        infoDate: last.date,
      );
    }
    st.quotes = quotes;
    return st;
  }

  /// 真机视口 + 字体 1.3
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(400, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: makeState(),
      child: MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: page,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('真数据布局体检（400dp + 字体 1.3，数据来自他的备份）', () {
    testWidgets('持仓页（${back.assets.length} 只标的的真实名字与金额）不溢出', (tester) async {
      await pumpPage(tester, const HoldingsPage());
      expect(tester.takeException(), isNull,
          reason: '窄屏 + 大字体下不许 RenderFlex overflow');
    });

    testWidgets('全部交易页（${back.txns.length} 笔）不溢出', (tester) async {
      await pumpPage(tester, const AllTxnsPage());
      expect(tester.takeException(), isNull);
    });

    testWidgets('现金管理页（${back.cashTxns.length} 条流水）不溢出，且「收益」口径正确',
        (tester) async {
      final st = makeState();
      await pumpPage(tester, const CashManagePage());
      expect(tester.takeException(), isNull);
      // 「收益」只算货币基金/逆回购的利息（现金分红单列）
      final income = back.cashTxns
          .where((c) => c.type == CashType.income)
          .fold<double>(0, (a, c) => a + c.amount);
      final dividend = back.cashTxns
          .where((c) => c.type == CashType.dividend)
          .fold<double>(0, (a, c) => a + c.amount);
      expect(st.cashTotalIncome, closeTo(income, 1e-6));
      expect(st.cashTotalDividend, closeTo(dividend, 1e-6));
    });

    testWidgets('编辑一条真实记录：顶部只有它自己那一个操作行为，保存置灰', (tester) async {
      final t = back.txns.where((t) => t.type == TxnType.buy && t.isReinvest).toList();
      if (t.isEmpty) {
        markTestSkipped('备份里没有红利再投的记录');
        return;
      }
      await pumpPage(tester, TxnEditPage(existing: t.first));
      expect(tester.takeException(), isNull);
      expect(find.text('再投'), findsOneWidget, reason: '红利再投要显示成「再投」');
      expect(find.text('卖出'), findsNothing);
      expect(find.text('改为待确认'), findsNothing);
      final btn = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '保存'));
      expect(btn.onPressed, isNull, reason: '没改动不该能保存');
    });
  });
}
