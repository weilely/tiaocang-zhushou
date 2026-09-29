import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'widgets/macro_card.dart';

/// 「历史曲线」的**横屏全屏**页
///
/// 用户 2026-09-29：「这个图能不能旋转方向，旋转适配屏幕尺寸」。
///
/// 为什么单独开一页：竖屏 400dp 宽要画 21 年（2005-04-08 起 5000 多个交易日），
/// 绘图区只有 ~330dp，点全挤在一起；横过来是 **880×400**，绘图区宽一倍多，
/// Y 轴刻度、两条线都能看清。反过来，让首页整页跟着手机横过来会很难用
/// （列表、底部导航都是按竖屏排的），所以**只在这一页放开横屏**。
///
/// 进出场口径：进页面 `setPreferredOrientations(横屏两个方向)` +
/// 沉浸式（把状态栏/导航栏藏起来，图能占满）；退出时用**空列表**恢复
/// 「跟随系统」——这正是 App 原本的状态，不留副作用。
class MacroChartPage extends StatefulWidget {
  const MacroChartPage({super.key});

  @override
  State<MacroChartPage> createState() => _MacroChartPageState();
}

class _MacroChartPageState extends State<MacroChartPage> {
  final ErpChartController _chart = ErpChartController();

  @override
  void initState() {
    super.initState();
    // 横屏两个方向都允许：用户左手右手拿着都能用
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 叠加线的历史**只补一次**（只读库、不发请求）。
    // 注意别放在 `build` 里：库读不进来时它会 `notifyListeners` 触发重建 →
    // 又在 build 里拉一次 → 帧永远停不下来（测试里就是 `pumpAndSettle` 超时）。
    final st = context.read<AppState>();
    if (st.benchmarkNavs.isEmpty) unawaited(st.loadIndexNavs());
  }

  @override
  void dispose() {
    // 锁回**竖屏**（App 的常态，见 `main.dart`）：用空列表"跟随系统"是不行的 ——
    // 手机上开了自动旋转时，退出这一页会停在横屏，整个 App 都跟着横过来。
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _chart.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final theme = Theme.of(context);
    final indexSeries = st.benchmarkNavs;
    final latest = st.macroLatest;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 2),
                  const Text('历史曲线',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  _legend(theme.colorScheme.primary, '股债利差（左轴 %）'),
                  if (indexSeries.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    _legend(kErpIndexLine,
                        '${st.benchmark.indexName} 区间收益（右轴 %）'),
                  ],
                  const Spacer(),
                  if (latest != null)
                    Text(
                      '${latest.date} · 利差 ${latest.erp.toStringAsFixed(2)}%',
                      style:
                          TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  const SizedBox(width: 8),
                  // 横屏也能用按钮缩放：屏幕上更容易按
                  ListenableBuilder(
                    listenable: _chart,
                    builder: (ctx, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _zoom(Icons.remove, '缩小', _chart.canZoomIn,
                            _chart.zoomOut),
                        _zoom(Icons.add, '放大', _chart.canZoomIn,
                            _chart.zoomIn),
                        _zoom(Icons.restart_alt, '复位', !_chart.isFull,
                            _chart.reset),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // **Expanded**：图跟着屏幕尺寸走 —— 横屏有多高就画多高
              Expanded(
                child: ErpChart(
                  rows: st.macroHistory,
                  indexSeries: indexSeries,
                  interactive: true,
                  alignToErp: st.alignErpIndex,
                  controller: _chart,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '双指缩放 / 单指拖动 / 双击复位；${st.benchmark.indexName} '
                '这条线的区间收益以当前可见窗口的第一天为基准。'
                '返回后自动转回竖屏。',
                style: TextStyle(fontSize: 10, color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legend(Color color, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 2.5, color: color),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      );

  Widget _zoom(IconData icon, String tip, bool enabled, VoidCallback onTap) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        icon: Icon(icon, size: 18),
        onPressed: enabled ? onTap : null,
      );
}
