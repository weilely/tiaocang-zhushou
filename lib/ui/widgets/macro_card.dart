import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../logic/macro_allocation.dart';
import '../../state/app_state.dart';

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
    final erpColor = erp >= 5.5
        ? const Color(0xFFD93A3A)
        : (erp >= 4.0 ? const Color(0xFFB4770A) : const Color(0xFF1A9C5B));

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
                      _subtitle(st, latest),
                      style: TextStyle(fontSize: 10, color: theme.hintColor),
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
                  child: _ErpChart(rows: st.macroHistory),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(
                  _explain(st),
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

  /// 展开后的说明文字：利差口径 + **按分位折算的股债比** + 免责
  ///
  /// 股债比是用户 2026-09-22 要的，口径指定 **10 年**。所以优先用**本地利差分位**
  /// —— 回填已经把本地历史补到约 10 年（东财数据中心的中美国债收益率 +
  /// 中证官网日频 PE），这才是"股债利差本身"的 10 年分位。
  /// 本地样本还不够长（回填失败/新装）时才退到蛋卷的长窗口 PE 分位，
  /// 再不行就不折算 —— **每一条都把自己的口径与样本写出来**，不混着说。
  String _explain(AppState st) {
    final buf = StringBuffer(
        '利差 = 沪深300盈利收益率(1/PE) − 10年国债收益率；越大说明股票相对债券越便宜。');

    final ep = st.macroErpPercentile;
    final lp = st.macroPePercentileLong;
    final days = st.macroHistory.length;
    if (ep != null && days >= _minDaysForSplit) {
      buf.write('按本地利差分位（$days 天：${st.macroSampleRange}）折算：'
          '${equityBondSplitText(ep)}'
          '（＝分位×100 给权益、其余给债券，纯机械折算）。');
    } else if (lp != null) {
      final win = _ym(st.macroPeWindowStart);
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
  static const int _minDaysForSplit = 250;

  /// 副标题：分位 + **样本区间**（必须写年限，否则容易被当成长周期分位）
  String _subtitle(AppState st, MacroRow latest) {
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
      final win = _ym(st.macroPeWindowStart);
      parts.add('沪深300 PE 长窗口分位 ${(lp * 100).toStringAsFixed(0)}%'
          '${win.isEmpty ? '' : '（$win 起）'}');
    }
    return parts.join('　·　');
  }

  /// `2016-06`；拿不到就空串（宁可不写，也不写个猜的年份）
  static String _ym(DateTime? d) => d == null
      ? ''
      : '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// 股债利差历史曲线（自绘，单序列 + 中位参考线）
class _ErpChart extends StatelessWidget {
  const _ErpChart({required this.rows});
  final List<MacroRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rows.length < 2) {
      return Center(
        child: Text('再攒几天就能画曲线了',
            style: TextStyle(fontSize: 11, color: theme.hintColor)),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _ErpPainter(
        values: [for (final r in rows) r.erp],
        firstLabel: _md(rows.first.date),
        lastLabel: _md(rows.last.date),
        line: theme.colorScheme.primary,
        ref: theme.hintColor.withValues(alpha: 0.5),
        hint: theme.hintColor,
        grid: theme.dividerColor.withValues(alpha: 0.5),
      ),
    );
  }

  /// `2026-09-18` → `09-18`（横轴只要月日，省地方）
  static String _md(String iso) =>
      iso.length >= 10 ? iso.substring(5, 10) : iso;
}

class _ErpPainter extends CustomPainter {
  _ErpPainter({
    required this.values,
    required this.firstLabel,
    required this.lastLabel,
    required this.line,
    required this.ref,
    required this.hint,
    required this.grid,
  });

  final List<double> values;
  final String firstLabel;
  final String lastLabel;
  final Color line;
  final Color ref;
  final Color hint;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 30.0, padR = 6.0, padT = 8.0, padB = 16.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;
    if (w <= 0 || h <= 0 || values.length < 2) return;

    var lo = values.reduce((a, b) => a < b ? a : b);
    var hi = values.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 0.5) {
      // 样本太集中时撑开一点，否则曲线会贴边看不出形状
      final mid = (hi + lo) / 2;
      lo = mid - 0.25;
      hi = mid + 0.25;
    }
    final span = hi - lo;
    double yOf(double v) => padT + (1 - (v - lo) / span) * h;
    double xOf(int i) => padL + w * i / (values.length - 1);

    // 横向网格 + 左右刻度（最高/最低）
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 0.7;
    for (final v in [hi, (hi + lo) / 2, lo]) {
      final y = yOf(v);
      canvas.drawLine(Offset(padL, y), Offset(size.width - padR, y), gp);
      _text(canvas, '${v.toStringAsFixed(1)}%', Offset(0, y - 5),
          fontSize: 9, color: hint);
    }

    // 中位数参考线（虚线）
    final sorted = [...values]..sort();
    final median = sorted[sorted.length ~/ 2];
    final my = yOf(median);
    final dash = Paint()
      ..color = ref
      ..strokeWidth = 0.9;
    for (var x = padL; x < size.width - padR; x += 6) {
      canvas.drawLine(Offset(x, my), Offset(x + 3, my), dash);
    }

    // 折线
    final path = Path()..moveTo(xOf(0), yOf(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(xOf(i), yOf(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // 最后一个点画个实心圆，方便看出"当前在哪"
    canvas.drawCircle(
        Offset(xOf(values.length - 1), yOf(values.last)), 2.6,
        Paint()..color = line);

    // 横轴首尾日期
    _text(canvas, firstLabel, Offset(padL, size.height - 11),
        fontSize: 9, color: hint);
    _text(canvas, lastLabel, Offset(size.width - padR - 26, size.height - 11),
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

  @override
  bool shouldRepaint(covariant _ErpPainter old) =>
      old.values.length != values.length ||
      old.line != line ||
      old.lastLabel != lastLabel;
}
