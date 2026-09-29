import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../data/nav_models.dart';
import '../../logic/macro_allocation.dart';
import '../../state/app_state.dart';
import '../index_insight_page.dart';

/// 「市场估值」卡片：股债利差 + 沪深300 PE + 10年国债 + 历史分位
///
/// 说明几点设计取舍：
/// - 只呈现**数值与历史分位**，不给买卖建议 —— 它是估值温度计，不是择时信号。
/// - 分位必须**标明年限**：免费可得的数据里国债收益率只有 2023-05 起的历史，
///   本地累积也还不长，不写清楚会让人误以为是长周期分位。
/// - 曲线复用项目既有约定：自绘 `CustomPainter`，不引第三方图表库。
class MacroCard extends StatefulWidget {
  const MacroCard({super.key});

  @override
  State<MacroCard> createState() => _MacroCardState();
}

class _MacroCardState extends State<MacroCard> {
  bool _expanded = false;
  bool _busy = false;

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await context.read<AppState>().refreshMacro(force: true);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final latest = st.macroLatest;
    final theme = Theme.of(context);

    if (latest == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Row(
          children: [
            Icon(Icons.ssid_chart, size: 15, color: theme.hintColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                st.macroError ?? '市场估值取数中…',
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
            ),
            if (_busy)
              const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              InkWell(
                onTap: _refresh,
                child: Icon(Icons.refresh, size: 15, color: theme.hintColor),
              ),
          ],
        ),
      );
    }

    final erp = latest.erp;
    // 利差高低用颜色暗示"股票相对便宜/贵"，但不下结论
    final erpColor = macroErpColor(erp);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('股债利差',
                            style: TextStyle(
                                fontSize: 12, color: theme.hintColor)),
                        const SizedBox(width: 8),
                        Text('${erp.toStringAsFixed(2)}%',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: erpColor)),
                        const SizedBox(width: 10),
                        Text('沪深300 PE ${latest.hs300Pe.toStringAsFixed(2)}',
                            style: TextStyle(
                                fontSize: 11, color: theme.hintColor)),
                        const SizedBox(width: 10),
                        Text('10年国债 ${latest.cn10y.toStringAsFixed(2)}%',
                            style: TextStyle(
                                fontSize: 11, color: theme.hintColor)),
                        const Spacer(),
                        if (_busy)
                          const SizedBox(
                              width: 13,
                              height: 13,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                        else
                          GestureDetector(
                            onTap: _refresh,
                            child: Icon(Icons.refresh,
                                size: 15, color: theme.hintColor),
                          ),
                        const SizedBox(width: 6),
                        Icon(
                            _expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 18,
                            color: theme.hintColor),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      macroSubtitleText(st, latest),
                      style: TextStyle(fontSize: 10, color: theme.hintColor),
                    ),
                    const SizedBox(height: 6),
                    // **一个入口**：指数看板（页内用标签切换：低估榜 / 市场估值 / 查指数）
                    // —— 用户 2026-09-29 口径「集成到一个页面，入口还在关注页」。
                    InkWell(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const IndexInsightPage(),
                      )),
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dashboard_customize,
                              size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text('指数看板（低估榜 / 市场估值 / 查指数）',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary)),
                          Icon(Icons.chevron_right,
                              size: 16, color: theme.colorScheme.primary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: SizedBox(
                  height: 132,
                  child: ErpChart(rows: st.macroHistory),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(
                  macroExplainText(st),
                  style: TextStyle(
                      fontSize: 10, color: theme.hintColor, height: 1.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 展开后的说明文字：利差口径 + **按分位折算的股债比** + 免责
///
/// 股债比是用户 2026-09-22 要的，口径指定 **10 年**。所以优先用**本地利差分位**
/// —— 回填已经把本地历史补到约 10 年（东财数据中心的中美国债收益率 +
/// 中证官网日频 PE），这才是"股债利差本身"的 10 年分位。
/// 本地样本还不够长（回填失败/新装）时才退到蛋卷的长窗口 PE 分位，
/// 再不行就不折算 —— **每一条都把自己的口径与样本写出来**，不混着说。
///
/// （2026-09-29 从 `_MacroCardState` 的私有方法提成公共函数：「指数看板」页也用它）
String macroExplainText(AppState st) {
  final buf = StringBuffer(
      '利差 = 沪深300盈利收益率(1/PE) − 10年国债收益率；越大说明股票相对债券越便宜。');

  final ep = st.macroErpPercentile;
  final lp = st.macroPePercentileLong;
  final days = st.macroHistory.length;
  if (ep != null && days >= kMacroMinDaysForSplit) {
    buf.write('按本地利差分位（$days 天：${st.macroSampleRange}）折算：'
        '${equityBondSplitText(ep)}'
        '（＝分位×100 给权益、其余给债券，纯机械折算）。');
  } else if (lp != null) {
    final win = macroYm(st.macroPeWindowStart);
    buf.write('按沪深300 PE 长窗口分位${win.isEmpty ? '' : '（$win 起）'}折算：'
        '${equityBondSplitText(lp)}（纯机械折算）。');
  } else if (ep != null) {
    buf.write('分位样本只有 $days 天，先按本地利差分位折算：'
        '${equityBondSplitText(ep)}（纯机械折算）。');
  } else {
    buf.write('分位样本不足，暂不折算股债比。');
  }
  buf.write('仅为市场估值参考，不构成投资建议。');
  return buf.toString();
}

/// 用本地利差分位折算所需的最少天数（约 1 年）。
///
/// 低于这个数就不拿它当"10 年口径"用：要么退到蛋卷长窗口，要么如实说样本太短。
const int kMacroMinDaysForSplit = 250;

/// 副标题：分位 + **样本区间**（必须写年限，否则容易被当成长周期分位）
String macroSubtitleText(AppState st, MacroRow latest) {
  final parts = <String>[];
  final p = st.macroErpPercentile;
  if (p == null) {
    parts.add('本地样本 ${st.macroHistory.length} 天，攒够 20 天后显示分位');
  } else {
    parts.add('利差分位 ${(p * 100).toStringAsFixed(0)}%'
        '（本地 ${st.macroHistory.length} 天：${st.macroSampleRange}）');
  }
  final lp = st.macroPePercentileLong;
  if (lp != null) {
    final win = macroYm(st.macroPeWindowStart);
    parts.add('沪深300 PE 长窗口分位 ${(lp * 100).toStringAsFixed(0)}%'
        '${win.isEmpty ? '' : '（$win 起）'}');
  }
  return parts.join('　·　');
}

/// 利差高低的颜色暗示（高=红、中=橙、低=绿）——只作视觉提示，不下结论
Color macroErpColor(double erp) => erp >= 5.5
    ? const Color(0xFFD93A3A)
    : (erp >= 4.0 ? const Color(0xFFB4770A) : const Color(0xFF1A9C5B));

/// `2016-06`；拿不到就空串（宁可不写，也不写个猜的年份）
String macroYm(DateTime? d) =>
    d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}';


/// 曲线可见窗口（0~1，相对整段样本）—— 缩放/平移都在它上面算，**纯数据、可单测**
@immutable
class ChartWindow {
  /// 可见区间起点（0 = 最早那条样本）
  final double start;

  /// 可见区间终点（1 = 最新那条样本）
  final double end;

  const ChartWindow(this.start, this.end);

  /// 全览
  static const ChartWindow full = ChartWindow(0, 1);

  /// 最小可见比例（再小就只剩一两个点，看不出形状）
  static const double minSpan = 0.05;

  bool get isFull => start <= 0.0001 && end >= 0.9999;

  double get span => end - start;

  /// 夹回 [0,1]，且不超过 [minSpan]
  ChartWindow clamp() {
    var s = start;
    var e = end;
    if (!s.isFinite || !e.isFinite) return full;
    if (e - s < minSpan) e = s + minSpan;
    if (e - s > 1) {
      s = 0;
      e = 1;
    }
    if (s < 0) {
      e -= s;
      s = 0;
    }
    if (e > 1) {
      s -= (e - 1);
      e = 1;
    }
    return ChartWindow(s.clamp(0.0, 1.0), e.clamp(0.0, 1.0));
  }

  /// 以 [focal]（0~1，手指位置）为锚点缩放：`factor > 1` = 放大
  ChartWindow zoomed(double factor, double focal) {
    if (!factor.isFinite || factor <= 0) return this;
    final newSpan = (span / factor).clamp(minSpan, 1.0);
    final s = focal - (focal - start) * (newSpan / span);
    return ChartWindow(s, s + newSpan).clamp();
  }

  /// **右端锚定**缩放：右边（最新那天）不动，只收/放左边。
  ///
  /// 用户 2026-09-29：「指数看板里的市场估值在缩放的时候保证右侧日期最新，
  /// 只缩放左侧」—— 原来按正中缩放，一放大右边的最新日期就滑出屏幕了。
  ChartWindow zoomedRight(double factor) {
    if (!factor.isFinite || factor <= 0) return this;
    final newSpan = (span / factor).clamp(minSpan, 1.0);
    return ChartWindow(end - newSpan, end).clamp();
  }

  /// 平移：`dx` 是窗口宽度的倍数（正 = 往右看，即看更晚的数据）
  ChartWindow panned(double dx) =>
      ChartWindow(start + dx * span, end + dx * span).clamp();

  /// 落到样本下标：返回 **(i0, i1)** 闭区间（至少两个点，否则画不出线）
  (int, int) slice(int n) {
    if (n <= 1) return (0, n - 1);
    final i0 = (start * (n - 1)).floor().clamp(0, n - 2);
    final i1 = (end * (n - 1)).ceil().clamp(i0 + 1, n - 1);
    return (i0, i1);
  }
}

/// 图里的左右边距（缩放时手指位置换算成比例要用同一套，别写两遍）
const double kErpPadL = 30;
const double kErpPadR = 6;

/// 叠加的指数线颜色 —— 与「趋势图」里的大盘收益线同一支蓝，别另造一个
const Color kErpIndexLine = Color(0xFF4A90D9);

/// 曲线窗口的控制器：**缩放按钮和曲线共用同一个窗口状态**
///
/// （手机上双指缩放不好按，而且按钮更直观；手势依然支持）
class ErpChartController extends ChangeNotifier {
  ChartWindow _win = ChartWindow.full;

  ChartWindow get window => _win;
  bool get isFull => _win.isFull;
  bool get canZoomIn => _win.span > ChartWindow.minSpan + 1e-6;

  void set(ChartWindow w) {
    final c = w.clamp();
    if ((c.start - _win.start).abs() < 1e-9 && (c.end - _win.end).abs() < 1e-9) {
      return;
    }
    _win = c;
    notifyListeners();
  }

  /// 放大 / 缩小：**右端锚定**（最新那天不动，只收放左边）—— 用户 2026-09-29 口径。
  /// 手势那边同理：只要视图右端已经在最新处，双指缩放也按右端锚定。
  void zoomIn([double factor = 1.6]) => set(_win.zoomedRight(factor));
  void zoomOut([double factor = 1.6]) => set(_win.zoomedRight(1 / factor));
  void reset() => set(ChartWindow.full);
}

/// 股债利差历史曲线（自绘，**不引图表库**）。
///
/// - 主序列：**股债利差**（左轴 %）+ 中位参考线
/// - 可选叠加：**沪深300 区间收益**（右轴 %）—— 与库里的沪深300 日线按**日期对齐**，
///   早于它的一段没有数据就**不画**（不插值、不补零）；区间收益以**可见窗口的第一天**为基准，
///   所以缩放后看到的就是"这段区间里沪深300 涨跌了多少"
/// - [interactive] 时支持 **双指缩放 / 单指拖动 / 双击复位**
class ErpChart extends StatefulWidget {
  const ErpChart({
    super.key,
    required this.rows,
    this.indexSeries = const [],
    this.interactive = false,
    this.controller,
  });

  final List<MacroRow> rows;

  /// 叠加的指数日线（沪深300 = `AppState.benchmarkNavs`）
  final List<NavPoint> indexSeries;

  /// 是否可缩放/拖动（关注页那张小卡不开，免得和外层的展开/滚动打架）
  final bool interactive;

  /// 外部控制器（给了就用它当窗口状态 —— 缩放按钮与手势共用）
  final ErpChartController? controller;

  @override
  State<ErpChart> createState() => _ErpChartState();
}

/// 横轴 = **利差日期 ∪ 指数日线日期**，顺带把两条线各自在轴上的取值算好
///
/// 用户 2026-09-29：「市场估值历史曲线图沪深300收益补的数据没有显示完全」。
/// 以前横轴只取利差那 2958 天（2016-08-15 起），而沪深300 的日线已经补到
/// **2005-04-08**（5219 条）—— 补进来的 2761 条早于利差起点的数据**没有位置可画**，
/// 所以那条线看起来永远"缺一段"。
///
/// 合并成并集后：利差线在**自己有数据的日期**照常画，没有的日期留 `null`（断线，
/// 不插值不补零）；指数线则能一路画到 2005。两条线仍然严格按日期对齐 ——
/// 这跟"同一天才有值、对不上就是 null"是同一条口径。
({List<String> dates, List<double?> erp, List<double?> idx}) erpChartAxis(
  List<MacroRow> rows,
  List<NavPoint> indexSeries,
) {
  final erpBy = {for (final r in rows) r.date: r.erp};
  final idxBy = {for (final p in indexSeries) p.date: p.nav};
  final dates = <String>{...erpBy.keys, ...idxBy.keys}.toList()..sort();
  return (
    dates: dates,
    erp: [for (final d in dates) erpBy[d]],
    idx: [for (final d in dates) idxBy[d]],
  );
}

class _ErpChartState extends State<ErpChart> {
  double _prevScale = 1;
  double _focal = 0.5;

  ErpChartController? _own;

  /// 有外部控制器就用外部的，否则自己造一个（手势照样能用）
  ErpChartController get _ctrl {
    final ext = widget.controller;
    if (ext != null) return ext;
    return _own ??= ErpChartController();
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  /// 指数日线按**同一天**对齐到横轴：对不上就是 null（不插值、不补零）
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 轴 = 利差 ∪ 指数（见 [erpChartAxis]）：补进来的早年日线也要有位置画
    final axis = erpChartAxis(widget.rows, widget.indexSeries);
    final erpCount = axis.erp.where((v) => v != null).length;
    final idxCount = axis.idx.where((v) => v != null).length;
    if (axis.dates.length < 2 || (erpCount < 2 && idxCount < 2)) {
      return Center(
        child: Text('再攒几天就能画曲线了',
            style: TextStyle(fontSize: 11, color: theme.hintColor)),
      );
    }
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (ctx, _) {
        final win = widget.controller?.window ?? _own!.window;
        final (i0, i1) = win.slice(axis.dates.length);
        final dateSlice = axis.dates.sublist(i0, i1 + 1);
        final chart = CustomPaint(
          size: Size.infinite,
          painter: _ErpPainter(
            values: axis.erp.sublist(i0, i1 + 1),
            indexValues: axis.idx.sublist(i0, i1 + 1),
            // 横轴**带年份**（用户 2026-09-29 要求）：只写 `08-15` 看不出是哪一年，
            // 十年窗口下那两个标签会被读成"一个多月"
            firstLabel: dateSlice.first,
            lastLabel: dateSlice.last,
            line: theme.colorScheme.primary,
            ref: theme.hintColor.withValues(alpha: 0.5),
            hint: theme.hintColor,
            grid: theme.dividerColor.withValues(alpha: 0.5),
          ),
        );
        if (!widget.interactive) return chart;
        return LayoutBuilder(
          builder: (c2, box) {
            final plotW = (box.maxWidth - kErpPadL - kErpPadR).clamp(1.0, 1e6);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 双击复位（缩放后回全览）
              onDoubleTap: () => _ctrl.reset(),
              onScaleStart: (d) {
                _prevScale = 1;
                _focal =
                    ((d.localFocalPoint.dx - kErpPadL) / plotW).clamp(0.0, 1.0);
              },
              onScaleUpdate: (d) {
                // 缩放（相对上一次的增量）。**右端在最新处时按右端锚定**
                // （用户 2026-09-29：缩放要保证右侧日期最新，只缩左边）；
                // 已经拖到历史里去了就按手指落点锚，免得被强行拽回右边。
                if ((d.scale - _prevScale).abs() > 0.002) {
                  final delta = d.scale / _prevScale;
                  final atLatest = _ctrl.window.end >= 1.0 - 1e-9;
                  _ctrl.set(atLatest
                      ? _ctrl.window.zoomedRight(delta)
                      : _ctrl.window.zoomed(delta, _focal));
                }
                // 平移（单指拖动也走这里；手指右移 = 看更早的数据）
                final dx = d.focalPointDelta.dx / plotW;
                if (dx.abs() > 0.0005) _ctrl.set(_ctrl.window.panned(-dx));
                _prevScale = d.scale;
              },
              child: chart,
            );
          },
        );
      },
    );
  }

}

class _ErpPainter extends CustomPainter {
  _ErpPainter({
    required this.values,
    required this.indexValues,
    required this.firstLabel,
    required this.lastLabel,
    required this.line,
    required this.ref,
    required this.hint,
    required this.grid,
  });

  /// 与 [indexValues] 等长、按日期对齐的**股债利差**；null = 那天没有利差数据
  ///
  /// 会为 null 是因为横轴是**两条序列的并集**：沪深300 的日线补到了 2005，
  /// 而利差（PE + 10 年国债）只有 2016-08-15 起 —— 2016 之前这段只有指数线。
  final List<double?> values;

  /// 与 [values] 等长、按日期对齐的指数点位；null = 那天没有指数数据
  final List<double?> indexValues;

  final String firstLabel;
  final String lastLabel;
  final Color line;
  final Color ref;
  final Color hint;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    const padT = 8.0, padB = 16.0;
    final hasIndex = indexValues.any((v) => v != null && v > 0);
    final padR = hasIndex ? 34.0 : kErpPadR; // 右轴要留出刻度的地方
    final w = size.width - kErpPadL - padR;
    final h = size.height - padT - padB;
    if (w <= 0 || h <= 0 || values.length < 2) return;

    // 利差自己的取值范围（跳过轴上的空洞）；一个值都没有就只画指数线
    final erpNums = [for (final v in values) ?v];
    final hasErp = erpNums.length >= 2;
    var lo = 0.0, hi = 0.0, span = 1.0;

    double yOf(double v) => padT + (1 - (v - lo) / span) * h;
    double xOf(int i) => kErpPadL + w * i / (values.length - 1);

    if (hasErp) {
      lo = erpNums.reduce((a, b) => a < b ? a : b);
      hi = erpNums.reduce((a, b) => a > b ? a : b);
      if (hi - lo < 0.5) {
        final mid = (hi + lo) / 2; // 样本太集中时撑开一点，否则曲线贴边看不出形状
        lo = mid - 0.25;
        hi = mid + 0.25;
      }
      span = hi - lo;

      // 横向网格 + 左刻度（最高/中/最低）
      final gp = Paint()
        ..color = grid
        ..strokeWidth = 0.7;
      for (final v in [hi, (hi + lo) / 2, lo]) {
        final y = yOf(v);
        canvas.drawLine(Offset(kErpPadL, y), Offset(kErpPadL + w, y), gp);
        _text(canvas, '${v.toStringAsFixed(1)}%', Offset(0, y - 5),
            fontSize: 9, color: hint);
      }

      // 中位数参考线（虚线）
      final sorted = [...erpNums]..sort();
      final median = sorted[sorted.length ~/ 2];
      final my = yOf(median);
      final dash = Paint()
        ..color = ref
        ..strokeWidth = 0.9;
      for (var x = kErpPadL; x < kErpPadL + w; x += 6) {
        canvas.drawLine(Offset(x, my), Offset(x + 3, my), dash);
      }
    }

    // ── 右轴：沪深300 区间收益（以可见窗口第一个有值的点为基准）──────────
    if (hasIndex) {
      final base = indexValues.firstWhere((v) => v != null && v > 0)!;
      final pcts = [
        for (final v in indexValues) v == null || v <= 0 ? null : (v / base - 1) * 100,
      ];
      final nums = [for (final p in pcts) ?p];
      var lo2 = nums.reduce((a, b) => a < b ? a : b);
      var hi2 = nums.reduce((a, b) => a > b ? a : b);
      if (hi2 - lo2 < 2) {
        final mid = (hi2 + lo2) / 2;
        lo2 = mid - 1;
        hi2 = mid + 1;
      }
      final span2 = hi2 - lo2;
      double yOf2(double v) => padT + (1 - (v - lo2) / span2) * h;

      // 右刻度（上下两个值，蓝色 —— 和线同色，一眼能对上）
      for (final v in [hi2, lo2]) {
        _text(canvas, '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)}%',
            Offset(size.width - padR + 3, yOf2(v) - 5),
            fontSize: 8.5, color: kErpIndexLine);
      }

      final p2 = Path();
      var started = false;
      for (var i = 0; i < pcts.length; i++) {
        final v = pcts[i];
        if (v == null) {
          started = false; // 断开：没有数据的日期不连线
          continue;
        }
        if (!started) {
          p2.moveTo(xOf(i), yOf2(v));
          started = true;
        } else {
          p2.lineTo(xOf(i), yOf2(v));
        }
      }
      canvas.drawPath(
        p2,
        Paint()
          ..color = kErpIndexLine.withValues(alpha: 0.9)
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
      // 指数线末端小圆点
      for (var i = pcts.length - 1; i >= 0; i--) {
        if (pcts[i] != null) {
          canvas.drawCircle(Offset(xOf(i), yOf2(pcts[i]!)), 2.0,
              Paint()..color = kErpIndexLine);
          break;
        }
      }
    }

    // ── 主序列：股债利差（轴上空洞处断开，不插值）─────────────────────────
    if (hasErp) {
      final path = Path();
      var started = false;
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        if (v == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(xOf(i), yOf(v));
          started = true;
        } else {
          path.lineTo(xOf(i), yOf(v));
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
      // 末端圆点落在**最后一个有利差的日期**上
      for (var i = values.length - 1; i >= 0; i--) {
        final v = values[i];
        if (v != null) {
          canvas.drawCircle(Offset(xOf(i), yOf(v)), 2.6, Paint()..color = line);
          break;
        }
      }
    }

    // 横轴首尾日期（带年份；缩放后这俩跟着窗口变，等于告诉用户"现在在看哪一段"）
    _text(canvas, firstLabel, Offset(kErpPadL, size.height - 11),
        fontSize: 9, color: hint);
    // 尾标签**右对齐到绘图区右缘**（带年份后有 10 个字符，不能再硬减一个常数）
    _textRight(canvas, lastLabel, kErpPadL + w, size.height - 11,
        fontSize: 9, color: hint);
  }

  void _text(Canvas canvas, String s, Offset at,
      {required double fontSize, required Color color}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: fontSize, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  /// 右对齐绘制（[right] 是右边缘的 x）
  void _textRight(Canvas canvas, String s, double right, double y,
      {required double fontSize, required Color color}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: fontSize, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right - tp.width, y));
  }

  @override
  bool shouldRepaint(covariant _ErpPainter old) =>
      old.values.length != values.length ||
      old.indexValues.length != indexValues.length ||
      old.line != line ||
      old.lastLabel != lastLabel ||
      old.firstLabel != firstLabel;
}
