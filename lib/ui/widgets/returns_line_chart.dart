import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../logic/returns_calendar.dart';
import 'common.dart';

/// 区间累计收益率曲线：本组合 + 参考基准两条线
///
/// 自绘 `CustomPainter`，与项目「不引第三方图表库」的既有约定一致
/// （环形图也是自绘的）。
///
/// 拖动或点击图表会显示竖直指示线与浮动提示 `收益 +x.xx％` / `差值 +x.xx％`。
class ReturnsLineChart extends StatefulWidget {
  /// 本组合的区间累计收益率（%），按日期升序，起点为 0
  final List<ReturnPoint> points;

  /// 基准曲线，与 [points] 等长；取不到值的点为 `null`（该段基准线断开）
  final List<double?> refs;

  /// **第二条参考线**：自定义年化收益率那条（用户要求它**一直显示**，
  /// 而 [refs] 那条大盘指标是可切换的）。同样与 [points] 等长。
  final List<double?> refs2;

  /// 拖动/点击时回调当前活动的点下标（`null` = 松手）
  ///
  /// 浮动提示的文案由调用方渲染，所以把下标抛出去，避免这里备一套格式。
  final void Function(int? index)? onActiveChanged;

  final double height;

  const ReturnsLineChart({
    super.key,
    required this.points,
    required this.refs,
    this.refs2 = const [],
    this.onActiveChanged,
    this.height = 168,
  });

  @override
  State<ReturnsLineChart> createState() => _ReturnsLineChartState();
}

class _ReturnsLineChartState extends State<ReturnsLineChart> {
  /// 当前高亮的点：**默认落在最后一个点**，浮窗一进页面就看得见
  late int _active = _lastIndex;

  static const Color _mainColor = Color(0xFFD93A3A);

  /// 基准线用蓝色虚线（对齐 `pic/24.jpg`；之前用的灰色与设计稿不符）
  static const Color _refColor = Color(0xFF4A90D9);

  /// 第二条参考线（**自定义年化**，常显）用琥珀色虚线，和蓝色大盘线区分开
  static const Color _ref2Color = Color(0xFFE8A33D);

  int get _lastIndex => widget.points.isEmpty ? 0 : widget.points.length - 1;

  /// 浮层里的点选日期：`MM-dd`（年份在区间标签里已经有了，省宽度）
  static String _shortDate(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void didUpdateWidget(covariant ReturnsLineChart old) {
    super.didUpdateWidget(old);
    final changed = old.points.length != widget.points.length ||
        (old.points.isNotEmpty &&
            widget.points.isNotEmpty &&
            old.points.last.date != widget.points.last.date);
    if (changed) {
      // 换了区间/换了数据：重新贴到最后一个点
      _active = _lastIndex;
    } else if (_active > _lastIndex) {
      _active = _lastIndex;
    }
  }

  void _setActive(int idx) {
    if (idx == _active) return;
    setState(() => _active = idx);
    widget.onActiveChanged?.call(idx);
  }

  void _updateActive(Offset local, double width) {
    final n = widget.points.length;
    if (n < 2 || width <= 0) return;
    final ratio = (local.dx / width).clamp(0.0, 1.0);
    final idx = (ratio * (n - 1)).round().clamp(0, n - 1);
    _setActive(idx);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.length < 2) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            '该区间还没有净值数据，去关注页刷新净值',
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final geo = ChartGeometry(
          points: widget.points,
          // 两条参考线一起参与 Y 轴范围计算（ChartGeometry 只用这些值算上下界）
          refs: [...widget.refs, ...widget.refs2],
          size: Size(width, widget.height),
        );
        // 常显：始终有一个有效的高亮点（默认最后一个）
        final active = _active.clamp(0, widget.points.length - 1);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _updateActive(d.localPosition, width),
          onHorizontalDragStart: (d) => _updateActive(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _updateActive(d.localPosition, width),
          // 松手/点完都**不清空**：浮窗一直显示，停在用户最后看的那一点
          child: SizedBox(
            height: widget.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ChartPainter(
                      points: widget.points,
                      refs: widget.refs,
                      refs2: widget.refs2,
                      active: active,
                      mainColor: _mainColor,
                      refColor: _refColor,
                      ref2Color: _ref2Color,
                      hint: Theme.of(context).hintColor,
                      fillTop: _mainColor.withValues(alpha: 0.18),
                      fillBottom: _mainColor.withValues(alpha: 0.01),
                    ),
                  ),
                ),
                // 设计稿的浮动提示是**图内一个深色圆角浮层**，而不是图表上方一行文字
                _Callout(
                  left: geo.calloutLeft(active, count: widget.points.length),
                  top: geo.calloutTop(active, points: widget.points),
                  // 浮层只显示：账户收益 − 预期收益 的差值 + 点选日期
                  diff: (active < widget.refs2.length &&
                          widget.refs2[active] != null)
                      ? widget.points[active].pct - widget.refs2[active]!
                      : null,
                  date: _shortDate(widget.points[active].date),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<ReturnPoint> points;
  final List<double?> refs;

  /// 第二条参考线（**自定义年化**，常显；颜色与 [refs] 区分）
  final List<double?> refs2;
  final int? active;
  final Color mainColor;
  final Color refColor;
  final Color ref2Color;
  final Color hint;
  final Color fillTop;
  final Color fillBottom;

  _ChartPainter({
    required this.points,
    required this.refs,
    this.refs2 = const [],
    required this.active,
    required this.mainColor,
    required this.refColor,
    this.ref2Color = const Color(0xFFE8A33D),
    required this.hint,
    required this.fillTop,
    required this.fillBottom,
  });

  static const double _padLeft = ChartGeometry.padLeft;
  static const double _padRight = ChartGeometry.padRight;
  static const double _padTop = ChartGeometry.padTop;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final geo = ChartGeometry(points: points, refs: refs, size: size);
    final plotW = geo.plotW;
    final plotH = geo.plotH;
    if (plotW <= 0 || plotH <= 0) return;

    final lo = geo.lo;
    final hi = geo.hi;
    final yOf = geo.yOf;
    double xOf(int i) => geo.xOf(i, points.length);

    // ---- 横向网格 + Y 轴刻度（上 / 中 / 下）----
    final gridPaint = Paint()
      ..color = hint.withValues(alpha: 0.22)
      ..strokeWidth = 0.6;
    for (final t in [lo, (lo + hi) / 2, hi]) {
      final y = yOf(t);
      canvas.drawLine(Offset(_padLeft, y), Offset(size.width - _padRight, y),
          gridPaint);
      _label(canvas, fmtPct(t), Offset(_padLeft - 4, y),
          align: TextAlign.right, anchorRight: true);
    }

    // ---- 零基准线加粗一点 ----
    if (lo < 0 && hi > 0) {
      final zero = Paint()
        ..color = hint.withValues(alpha: 0.45)
        ..strokeWidth = 0.9;
      canvas.drawLine(Offset(_padLeft, yOf(0)),
          Offset(size.width - _padRight, yOf(0)), zero);
    }

    // ---- 基准线（虚线）：大盘指标 + 自定义年化，**两条都画** ----
    // 用户要求：「自定义那条线一直显示，切换的只是大盘指标」
    void drawRefSeries(List<double?> series, Color color) {
      if (series.isEmpty) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      var started = false;
      Offset? prev;
      for (var i = 0; i < series.length && i < points.length; i++) {
        final v = series[i];
        if (v == null) {
          started = false;
          prev = null;
          continue;
        }
        final p = Offset(xOf(i), yOf(v));
        if (started && prev != null) {
          _dashedLine(canvas, prev, p, paint);
        }
        prev = p;
        started = true;
      }
    }

    drawRefSeries(refs, refColor);
    drawRefSeries(refs2, ref2Color);

    // ---- 组合线 + 面积渐变 ----
    final line = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(xOf(i), yOf(points[i].pct));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
    }

    final area = Path.from(line)
      ..lineTo(xOf(points.length - 1), _padTop + plotH)
      ..lineTo(xOf(0), _padTop + plotH)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fillTop, fillBottom],
        ).createShader(
            Rect.fromLTWH(_padLeft, _padTop, plotW, plotH)),
    );

    canvas.drawPath(
      line,
      Paint()
        ..color = mainColor
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // ---- X 轴两端日期 ----
    _label(canvas, fmtMonthDay(points.first.date),
        Offset(_padLeft, _padTop + plotH + 5));
    _label(canvas, fmtMonthDay(points.last.date),
        Offset(size.width - _padRight, _padTop + plotH + 5),
        anchorRight: true);

    // ---- 活动指示 ----
    final a = active;
    if (a != null && a >= 0 && a < points.length) {
      final x = xOf(a);
      final y = yOf(points[a].pct);
      canvas.drawLine(
        Offset(x, _padTop),
        Offset(x, _padTop + plotH),
        Paint()
          ..color = hint.withValues(alpha: 0.6)
          ..strokeWidth = 0.8,
      );
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = mainColor);
      canvas.drawCircle(
          Offset(x, y), 4, Paint()
        ..color = Colors.white
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke);
      // 基准线上也画一个点（设计稿里那个蓝点）
      final rv = a < refs.length ? refs[a] : null;
      if (rv != null) {
        canvas.drawCircle(Offset(x, yOf(rv)), 3, Paint()..color = refColor);
      }
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final end = (t + dash) > total ? total : t + dash;
      canvas.drawLine(a + dir * t, a + dir * end, paint);
      t = end + gap;
    }
  }

  void _label(Canvas canvas, String text, Offset at,
      {TextAlign align = TextAlign.left, bool anchorRight = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9.5, color: hint),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = anchorRight ? at.dx - tp.width : at.dx;
    final dy = at.dy - tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.active != active ||
      old.points != points ||
      old.refs != refs ||
      old.mainColor != mainColor;
}

/// 图表的坐标换算
///
/// 画笔与「图内浮层」都要用同一套映射：浮层是 widget、曲线是 canvas，
/// 两边各算一遍迟早会错位，所以抽成一份。
class ChartGeometry {
  static const double padLeft = 46;
  static const double padRight = 8;
  static const double padTop = 14;
  static const double padBottom = 22;

  /// 浮层尺寸（内容固定两行，所以可以定死，避免首帧测量）
  static const double calloutWidth = 104;
  static const double calloutHeight = 46;

  final Size size;
  final double lo;
  final double hi;

  ChartGeometry({
    required List<ReturnPoint> points,
    required List<double?> refs,
    required this.size,
  })  : lo = _lo(points, refs),
        hi = _hi(points, refs);

  static double _rawLo(List<ReturnPoint> points, List<double?> refs) {
    var v = 0.0;
    for (final p in points) {
      if (p.pct < v) v = p.pct;
    }
    for (final r in refs) {
      if (r != null && r < v) v = r;
    }
    return v;
  }

  static double _rawHi(List<ReturnPoint> points, List<double?> refs) {
    var v = 0.0;
    for (final p in points) {
      if (p.pct > v) v = p.pct;
    }
    for (final r in refs) {
      if (r != null && r > v) v = r;
    }
    return v;
  }

  /// 算好上下留白后的范围；全是 0 时给一个对称假范围，别把线压在边上
  static double _lo(List<ReturnPoint> points, List<double?> refs) {
    final l = _rawLo(points, refs);
    final h = _rawHi(points, refs);
    if ((h - l).abs() < 1e-9) return -1;
    return l - (h - l) * 0.10;
  }

  static double _hi(List<ReturnPoint> points, List<double?> refs) {
    final l = _rawLo(points, refs);
    final h = _rawHi(points, refs);
    if ((h - l).abs() < 1e-9) return 1;
    return h + (h - l) * 0.10;
  }

  double get plotW => size.width - padLeft - padRight;
  double get plotH => size.height - padTop - padBottom;

  double yOf(double v) => padTop + plotH * (1 - (v - lo) / (hi - lo));

  double xOf(int i, int count) =>
      padLeft + plotW * (count <= 1 ? 0 : i / (count - 1));

  /// 浮层左边：贴着指示线右侧，快出界时翻到左侧，再兜底夹住
  double calloutLeft(int index, {required int count}) {
    final x = xOf(index, count);
    var left = x + 8;
    if (left + calloutWidth > size.width - padRight) left = x - 8 - calloutWidth;
    if (left < padLeft - 36) left = padLeft - 36;
    return left.clamp(0.0, (size.width - calloutWidth).clamp(0.0, double.infinity));
  }

  /// 浮层顶边：默认在点上方，越界就翻到下方
  double calloutTop(int index, {required List<ReturnPoint> points}) {
    final y = yOf(points[index].pct);
    var top = y - calloutHeight - 10;
    if (top < 0) top = y + 12;
    return top.clamp(0.0, (size.height - calloutHeight).clamp(0.0, double.infinity));
  }
}

/// 图内浮层：**只显示** 账户收益 − 预期收益 的**差值** + 点选日期（用户口径）
///
/// 三条线的具体数值不在这里显示 —— 点选那三个值放在**图上方**、期末三个值放在
/// **图下方**（见 `returns_stats_card` 的趋势视图）。
class _Callout extends StatelessWidget {
  final double left;
  final double top;

  /// 账户（实际）收益 − 预期收益 的差值；null 表示取不到
  final double? diff;

  /// 点选日期（已格式化，如 `09-21`）
  final String date;

  const _Callout({
    required this.left,
    required this.top,
    required this.diff,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      child: SizedBox(
        width: ChartGeometry.calloutWidth,
        // 浮窗不做底色（叠在曲线上更轻）；字色跟着主题走，
        // 深浅色主题下都协调，不再假死一块深灰。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (diff != null) _line(context, '差值', diff!),
            const SizedBox(height: 2),
            Text(date,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }

  /// 两行：标签用主题的次要文字色，数值用涨跌色
  Widget _line(BuildContext context, String label, double value) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor)),
          const SizedBox(width: 6),
          Text(fmtPct(value),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: pnlColor(value),
              )),
        ],
      );
}

/// 图例里的一小段虚线样式样本（对齐基准线的颜色与虚线）
class DashedLineSample extends StatelessWidget {
  final Color color;
  final double width;

  const DashedLineSample({
    super.key,
    this.color = const Color(0xFF4A90D9),
    this.width = 18,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 2,
      child: CustomPaint(painter: _DashSamplePainter(color)),
    );
  }
}

class _DashSamplePainter extends CustomPainter {
  final Color color;

  _DashSamplePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6;
    const dash = 3.0;
    const gap = 2.5;
    var x = 0.0;
    while (x < size.width) {
      final end = (x + dash) > size.width ? size.width : x + dash;
      canvas.drawLine(Offset(x, size.height / 2),
          Offset(end, size.height / 2), paint);
      x = end + gap;
    }
  }

  @override
  bool shouldRepaint(_DashSamplePainter old) => old.color != color;
}

/// 浮动提示的一行：`收益 +1.38％` / `差值 +1.31％`
class ChartTooltipRow extends StatelessWidget {
  final String label;
  final double value;

  const ChartTooltipRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final color = pnlColor(value);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11, color: Theme.of(context).hintColor)),
        const SizedBox(width: 6),
        Text(fmtPct(value),
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}
