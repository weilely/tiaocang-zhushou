import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/core/format.dart';
import 'package:invest_tracker/data/asset_traits.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';
import 'package:invest_tracker/logic/backup.dart';
import 'package:invest_tracker/logic/cash_flow.dart';
import 'package:invest_tracker/logic/range_preset.dart';
import 'package:invest_tracker/logic/redeem_fee.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/all_txns_page.dart';
import 'package:invest_tracker/ui/cash_manage_page.dart';
import 'package:invest_tracker/ui/holdings_page.dart';
import 'package:invest_tracker/ui/settings_page.dart';
import 'package:invest_tracker/ui/txn_edit_page.dart';
import 'package:invest_tracker/ui/widgets/returns_stats_card.dart';
import 'package:invest_tracker/ui/widgets/segmented_pills.dart';
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
  Future<void> pumpPage(WidgetTester tester, Widget page,
      {AppState? state}) async {
    tester.view.physicalSize = const Size(400, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state ?? makeState(),
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

    // 用户 2026-09-29：「全部交易列表默认按标的折叠，提头也和现金流水一样，
    // 可分类查看，按日期查看」
    testWidgets('全部交易：默认折叠 → 点开看明细 → 切按日期 → 按类型筛', (tester) async {
      await pumpPage(tester, const AllTxnsPage());
      expect(tester.takeException(), isNull);

      // ① 默认按标的折叠：一笔明细都不展开
      expect(find.byType(ListTile), findsNothing, reason: '默认折叠');

      // ② 点第一个标的的头 → 展开出明细，抬头是动作词（不是备注/份额）
      String nameOf(int id) {
        final hits = back.assets.where((a) => a.id == id).toList();
        if (hits.isEmpty) return '未知标的';
        final a = hits.first;
        return a.name.isEmpty ? a.code : a.name;
      }

      final byAsset = <int, List<Txn>>{};
      for (final t in back.txns) {
        (byAsset[t.assetId] ??= <Txn>[]).add(t);
      }
      final ids = byAsset.keys.toList()
        ..sort((x, y) => nameOf(x).compareTo(nameOf(y)));
      await tester.tap(find.text(nameOf(ids.first)).first);
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsWidgets, reason: '点开后有明细');
      expect(tester.takeException(), isNull);

      // ③ 切「按日期」：按月折叠（最近一个月默认展开），明细在副标题里
      await tester.tap(find.text('按日期'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('月'), findsWidgets, reason: '月份头');
      expect(find.textContaining(' 份 @ '), findsWidgets,
          reason: '按日期视图里明细在副标题');
      expect(find.byType(ListTile), findsWidgets);

      // ④ 按类型筛「再投」：只留红利再投那些行（抬头就是「再投」）
      final reinvestCount = back.txns.where((t) => t.isReinvest).length;
      await tester.tap(find.descendant(
          of: find.byType(PillGroup), matching: find.text('再投')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('共 $reinvestCount 笔'), findsOneWidget,
          reason: '筛选后抬头合计按筛完的算');
      // 抬头「再投」至少两处：筛选筹码 + 行标题
      expect(find.text('再投'), findsAtLeastNWidgets(2));
      expect(find.textContaining('· 定投'), findsNothing,
          reason: '筛了再投就不该有定投的行');
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

    // 用户 2026-09-29：「数据中心分红核对也不要了」「同花顺数据源提示太多了，
    // 把提示放到对话框里」
    testWidgets('设置页：分红核对入口已去掉、同花顺说明收进弹框', (tester) async {
      await pumpPage(tester, const SettingsPage());
      expect(tester.takeException(), isNull, reason: '整页不许溢出');

      // 两条被删掉的入口不该再出现
      expect(find.textContaining('分红核对'), findsNothing);
      expect(find.textContaining('补记「再投」'), findsNothing);

      // 同花顺卡片：正文里不再堆说明，改成标题栏的「?」
      // （页面是懒构建的，先滚到那张卡再点）
      await tester.scrollUntilVisible(find.text('同花顺数据源（备用）'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final help = find.byIcon(Icons.help_outline);
      expect(help, findsWidgets);
      await tester.tap(help.first);
      await tester.pumpAndSettle();
      expect(find.textContaining('行情兜底的第三路'), findsOneWidget,
          reason: '说明要能在弹框里看到');
      expect(tester.takeException(), isNull);
    });

    // 用户 2026-09-29：「首页收益统计的资金流最好显示区间日期」
    testWidgets('收益统计 → 资金流：把区间日期写出来', (tester) async {
      final st = makeState()..setStatsView(StatsView.flow);
      await pumpPage(tester, const ReturnsStatsCard(), state: st);
      expect(tester.takeException(), isNull);

      final r = st.flowRange;
      expect(find.textContaining(fmtDate(r.start)), findsWidgets,
          reason: '区间起始日');
      expect(find.textContaining(fmtDate(r.end)), findsWidgets,
          reason: '区间结束日');
      expect(find.textContaining(st.flowPreset.label), findsWidgets,
          reason: '连预设名一起写，才知道这是哪一段');
    });

    // 用户 2026-09-29：「在卖出标的时，在确认手续费的逻辑，尤其是基金卖出档位费率，
    // 要真实，当改变卖出数量时，后面相关的数据要随动，尤其是实际费用」
    testWidgets('卖出：档位用真档，改份额 → 「手续费（实际）」跟着重算', (tester) async {
      final st = makeState();
      final held = st.allPositions.where((p) => p.shares > 1).toList()
        ..sort((a, b) => b.shares.compareTo(a.shares));
      if (held.isEmpty) {
        markTestSkipped('备份里没有持仓');
        return;
      }
      final p = held.first;
      // 给这只基金一档「真实」费率：7 天内 1.5% / 7~30 天 0.5% / 30 天以上 0
      st.userRedeemTiers[p.asset.code] = const [
        RedeemTier(0, 7, 1.5),
        RedeemTier(7, 30, 0.5),
        RedeemTier(30, null, 0),
      ];

      await pumpPage(
        tester,
        TxnEditPage(
          presetAccountId: p.accountId,
          presetAsset: p.asset,
          presetType: TxnType.sell,
          maxShares: p.shares,
        ),
        state: st,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 档位取到了「你手动设的」那一档（不是默认档）→ 费用才是真的
      // （档位框和预测框的 helper 都会写这句，所以不止一处）
      expect(find.textContaining('档位是你设的'), findsWidgets);

      // 测试环境没有库/网，净值手填一个
      await tester.enterText(labelField(tester, '净值'), '1.20');
      await tester.pumpAndSettle();
      final full = labelText(tester, '手续费（实际）');
      expect(full, isNotEmpty, reason: '份额与净值都有 → 实际费用自动填出来');
      expect(double.tryParse(full), isNotNull);

      // 份额改成一半 → 实际费用必须跟着重算
      await tester.enterText(
          labelField(tester, '卖出份'), (p.shares / 2).toStringAsFixed(2));
      await tester.pumpAndSettle();
      final half = labelText(tester, '手续费（实际）');
      expect(half, isNot(full), reason: '份额变了，实际费用要随动');

      // 就算之前手改过「实际」，改份额也要把它拉回重算值
      await tester.enterText(labelField(tester, '手续费（实际）'), '9.99');
      await tester.pumpAndSettle();
      expect(labelText(tester, '手续费（实际）'), '9.99');
      await tester.enterText(
          labelField(tester, '卖出份'), (p.shares / 4).toStringAsFixed(2));
      await tester.pumpAndSettle();
      expect(labelText(tester, '手续费（实际）'), isNot('9.99'),
          reason: '改卖出数量后，实际费用不许停在手填的旧值上');
    });
  });
}

/// 某个 label 对应的输入框（TextFormField）
Finder labelField(WidgetTester tester, String label) => find
    .ancestor(of: find.text(label), matching: find.byType(TextFormField))
    .first;

/// 读某个输入框里的文本
String labelText(WidgetTester tester, String label) {
  final tf = tester.widget<TextField>(find
      .descendant(of: labelField(tester, label), matching: find.byType(TextField))
      .first);
  return tf.controller?.text ?? '';
}
