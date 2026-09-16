import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../state/app_state.dart';
import 'dashboard_page.dart';
import 'holdings_page.dart';
import 'rebalance_page.dart';
import 'settings_page.dart';
import 'watchlist_page.dart';
import 'widgets/common.dart';
import 'widgets/market_ticker.dart';

/// 底部导航的页签定义：**顺序就是页签顺序，标签同时用于标题栏**
///
/// 以前标题列表与导航项是两份独立的字面量，改名时容易只改一处；
/// 现在收敛成一份，`_titles` 由它派生，不跑真机也能直接断言页签。
const List<({String label, IconData icon, IconData selectedIcon})> kShellTabs = [
  (
    label: '首页',
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view,
  ),
  (
    label: '持仓',
    icon: Icons.pie_chart_outline,
    selectedIcon: Icons.pie_chart,
  ),
  (
    label: '调仓',
    icon: Icons.sync_alt_outlined,
    selectedIcon: Icons.sync_alt,
  ),
  (
    label: '关注',
    icon: Icons.star_border,
    selectedIcon: Icons.star,
  ),
  (
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

/// 设置页签的下标（外壳据此判断要不要显示「首页」才有的账户下拉与跑马灯）
const int kSettingsTabIndex = 4;

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  String? _shownError;

  /// 状态栏上证指数的自动刷新（只在「首页 + 前台」时跑，省电）
  Timer? _indexTimer;

  static final List<String> _titles =
      [for (final t in kShellTabs) t.label];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncIndexTimer();
  }

  @override
  void dispose() {
    _indexTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // 切到后台就停，回到前台再续 —— 别在兜里偷偷联网耗电
    _syncIndexTimer();
  }

  /// 60 秒一次；只在首页（指数就显示在那儿）且 App 在前台时开
  void _syncIndexTimer() {
    final wanted = _index == 0 && _lifecycleActive;
    if (wanted && _indexTimer == null) {
      _indexTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (!mounted) return;
        context.read<AppState>().refreshIndexQuotes();
      });
    } else if (!wanted) {
      _indexTimer?.cancel();
      _indexTimer = null;
    }
  }

  bool get _lifecycleActive {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _handleMessages(context, state);

    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _index == 0
            ? _dashboardTitle(context, state)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _titles[_index],
                    style:
                        const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    state.lastRefresh == null
                        ? '行情未更新'
                        : '行情更新 ${fmtDateTime(state.lastRefresh!)}',
                    style:
                        TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
        bottom: _index == 0 && state.tickerIndices.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(30),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: MarketTicker(quotes: state.tickerIndices),
                ),
              )
            : null,
        actions: [
          IconButton(
            tooltip: '刷新行情',
            onPressed: state.refreshing ? null : () => state.refreshQuotes(),
            icon: state.refreshing
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          DashboardPage(),
          HoldingsPage(),
          RebalancePage(),
          WatchlistPage(),
          SettingsPage(),
        ],
      ),
      // 记一笔已移到状态栏图标，这里不再放悬浮按钮
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _syncIndexTimer();
        },
        destinations: [
          for (final t in kShellTabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.selectedIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }

  /// 首页标题：账户下拉 + 上证（实时，只写两个字省地方）
  Widget _dashboardTitle(BuildContext context, AppState state) {
    final q = state.shanghaiIndex;
    final color = q == null
        ? Theme.of(context).hintColor
        : pnlColor(q.changePct);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: _accountSelector(context, state)),
        if (q != null) ...[
          const SizedBox(width: 10),
          Flexible(
            // 账户名 + 指数一起挤在 400dp 宽的标题栏里，缩一点也不能压到右边图标上
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('上证',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                  const SizedBox(width: 5),
                  Text(q.price.toStringAsFixed(2),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 5),
                  Text(
                    '${q.changePct >= 0 ? '+' : ''}${q.changePct.toStringAsFixed(2)}%',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: color),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 首页标题栏的账户下拉
  Widget _accountSelector(BuildContext context, AppState state) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.account_balance_wallet_outlined,
            size: 18, color: Theme.of(context).hintColor),
        const SizedBox(width: 6),
        DropdownButton<int?>(
          value: state.accountFilter,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('全部账户')),
            for (final a in state.accounts)
              DropdownMenuItem<int?>(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => state.setAccountFilter(v),
        ),
      ],
    );
  }

  void _handleMessages(BuildContext context, AppState state) {
    final msg = state.lastError ?? state.lastMessage;
    if (msg == null) {
      _shownError = null;
      return;
    }
    if (msg == _shownError) return;
    _shownError = msg;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
      state.clearError();
    });
  }
}
