import 'package:flutter/material.dart';

import '../../core/format.dart';

/// 曲线上的一个金额点
typedef ValuePoint = ({DateTime date, double value});

/// 「资产收益」卡片里的**金额曲线**（总资产 / 总收益）
///
/// 按参考图的样子：横向网格线 + 左侧金额刻度（万/亿，用 [fmtCompact]）+
/// 首尾日期 + 折线下方**面积填充**。自绘 `CustomPainter`，与项目
/// 「不引第三方图表库」的约定一致。
///
/// 曲线颜色由调用方定：总资产用主色（像图里那条蓝线），
/// 总收益按正负用涨跌色（赚红亏绿，跟 App 其它地方一致）。
class AssetValueChart extends StatelessWidget {
  final List<ValuePoint> points;
  final Color lineColor;

  /// 零轴要不要画：总收益会跨 0，总资产不会
  final bool showZeroLine;

  final double height;

  const AssetValueChart({
    super.key,
    required this.points,
    required this.lineColor,
    this.showZeroLine = false,
    this.height = 168,
  });

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('这段时间还没有足够的净值数据',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor)),
        ),
      );
    }
    final hint = Theme.of(context).hintColor;
    return SizedBox(
      height: height,
      child: CustomPaint(
        // ⚠️ 必须给尺寸：`CustomPaint` 没有 child 时用的是自身的 `size`（默认 0），
        // 放进 `SizedBox(height:)` 这种**宽度宽松**的约束里宽度会算成 0 —— 图上什么都看不到。
        // `Size.infinite` 会取满可用的最大约束（父级宽度），height 由外面那个 SizedBox 定。
        key: const Key('assetValueChart'),
        size: Size.infinite,
        painter: _ValueChartPainter(
          points: points,
          lineColor: lineColor,
          gridColor: Theme.of(context).dividerColor,
          labelColor: hint,
          showZeroLine: showZeroLine,
        ),
      ),
    );
  }
}

class _ValueChartPainter extends CustomPainter {
  final List<ValuePoint> points;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;
  final bool showZeroLine;

  const _ValueChartPainter({
    required this.points,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
    required this.showZeroLine,
  });

  /// 左侧留给金额刻度的宽度（"20.16万" 这种）
  static const double _labelW = 52;

  /// 底部留给日期的行高
  static const double _dateH = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final plotW = size.width - _labelW;
    final plotH = size.height - _dateH;
    if (plotW <= 8 || plotH <= 8) return;

    var lo = points.first.value;
    var hi = points.first.value;
    for (final p in points) {
      if (p.value < lo) lo = p.value;
      if (p.value > hi) hi = p.value;
    }
    // 全平（比如刚买入还没涨跌）：撑开一点，免得除以 0
    if ((hi - lo).abs() < 1e-9) {
      hi = lo + (lo.abs() < 1 ? 1 : lo.abs() * 0.01);
    }
    // 上下留 8% 余量，曲线不贴边
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    final span = hi - lo;

    double yOf(double v) => plotH * (1 - (v - lo) / span);
    final dx = plotW / (points.length - 1);

    // 1) 网格线 + 左侧刻度（5 档）
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.7;
    const ticks = 5;
    for (var i = 0; i < ticks; i++) {
      final v = hi - span * i / (ticks - 1);
      final y = yOf(v);
      canvas.drawLine(Offset(_labelW, y), Offset(size.width, y), grid);
      _text(canvas, fmtCompact(v), Offset(0, y - 6),
          fontSize: 10, color: labelColor);
    }

    // 2) 零轴（总收益跨 0 时才有意义）
    if (showZeroLine && lo < 0 && hi > 0) {
      final y0 = yOf(0);
      final dash = Paint()
        ..color = labelColor.withValues(alpha: 0.45)
        ..strokeWidth = 1;
      for (var x = _labelW; x < size.width; x += 5) {
        canvas.drawLine(Offset(x, y0), Offset((x + 3).clamp(_labelW, size.width), y0), dash);
      }
    }

    // 3) 面积 + 折线
    final path = Path()..moveTo(_labelW, yOf(points.first.value));
    for (var i = 1; i < points.length; i++) {
      path.lineTo(_labelW + i * dx, yOf(points[i].value));
    }
    final area = Path.from(path)
      ..lineTo(_labelW + plotW, plotH)
      ..lineTo(_labelW, plotH)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.22),
            lineColor.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(_labelW, 0, plotW, plotH)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
    // 末点
    canvas.drawCircle(Offset(size.width, yOf(points.last.value)), 2.4,
        Paint()..color = lineColor);

    // 4) 首尾日期（图里是完整日期）
    _text(canvas, fmtDate(points.first.date), Offset(_labelW, plotH + 4),
        fontSize: 10, color: labelColor);
    final last = fmtDate(points.last.date);
    final tp = _painter(last, 10, labelColor);
    tp.paint(canvas, Offset(size.width - tp.width, plotH + 4));
  }

  TextPainter _painter(String s, double fontSize, Color color) => TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(fontSize: fontSize, color: color)),
        textDirection: TextDirection.ltr,
      )..layout();

  void _text(Canvas canvas, String s, Offset at,
      {required double fontSize, required Color color}) {
    _painter(s, fontSize, color).paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _ValueChartPainter old) =>
      old.lineColor != lineColor ||
      old.points.length != points.length ||
      (old.points.isNotEmpty &&
          points.isNotEmpty &&
          (old.points.last.value != points.last.value ||
              old.points.last.date != points.last.date));
}
