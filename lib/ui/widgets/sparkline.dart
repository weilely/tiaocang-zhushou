import 'package:flutter/material.dart';

/// 迷你走势线（自绘，不引第三方图表库）
///
/// 两处在用：持仓卡的「今年以来收益率」小曲线、关注页右滑出来的「近一年收益曲线」。
/// 原来它是 `holdings_page.dart` 里的私有 painter —— 提出来共用，免得两处各画一套
/// 迟早画歪（同一个量两条实现路径是这个项目反复踩过的坑）。
class Sparkline extends StatelessWidget {
  final List<double> values;

  /// 线的颜色（跟着末值的涨跌走：红涨绿跌）
  final Color line;

  /// 线宽：小卡片里细一点，面板里粗一点
  final double strokeWidth;

  /// 数值序列全是同一个值时是否撑开（默认撑开，免得除以 0 贴边）
  final bool flattenIfFlat;

  const Sparkline({
    super.key,
    required this.values,
    required this.line,
    this.strokeWidth = 1.4,
    this.flattenIfFlat = true,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: SparklinePainter(
        values: values,
        line: line,
        strokeWidth: strokeWidth,
        flattenIfFlat: flattenIfFlat,
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color line;
  final double strokeWidth;
  final bool flattenIfFlat;

  const SparklinePainter({
    required this.values,
    required this.line,
    this.strokeWidth = 1.4,
    this.flattenIfFlat = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;

    var lo = values.first;
    var hi = values.first;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    var span = hi - lo;
    if (span.abs() < 1e-9) {
      if (!flattenIfFlat) return;
      // 全平（比如刚成立、还没波动）：撑开一点，免得除以 0 画成一条贴边的线
      hi = lo + 1;
      span = 1;
    }

    const pad = 2.0;
    final h = size.height - pad * 2;
    final dx = size.width / (values.length - 1);
    double yOf(double v) => pad + (1 - (v - lo) / span) * h;

    // 曲线跨 0 时画一条 0% 基准虚线，方便看"现在是赚还是亏"
    if (lo < 0 && hi > 0) {
      final y0 = yOf(0);
      final dash = Paint()
        ..color = line.withValues(alpha: 0.32)
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 4) {
        canvas.drawLine(Offset(x, y0), Offset(x + 2, y0), dash);
      }
    }

    final path = Path()..moveTo(0, yOf(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(i * dx, yOf(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round,
    );
    // 末点一个实心小圆（跟市场估值卡片一致，标出"现在在哪"）
    canvas.drawCircle(
        Offset(size.width, yOf(values.last)), 2.0, Paint()..color = line);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter old) =>
      old.line != line ||
      old.strokeWidth != strokeWidth ||
      old.values.length != values.length ||
      (old.values.isNotEmpty &&
          values.isNotEmpty &&
          old.values.last != values.last);
}
