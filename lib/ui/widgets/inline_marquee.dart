import 'package:flutter/material.dart';

/// 单行「跑马灯」：文字放得下就静态显示，放不下才横向来回滚动。
///
/// 持仓卡片的预估涨幅/预估收益用它 —— 一张卡一行，如果每条都无条件跑动画，
/// 长列表里会有几十个 AnimationController 一起刷新，既费电又晃眼；所以先用
/// LayoutBuilder + TextPainter 量一遍，**只有真的溢出才启动动画**。
class InlineMarquee extends StatefulWidget {
  final String text;

  /// 文字样式（颜色由调用方按涨跌给）
  final TextStyle style;

  /// 单程滚动时长（越长越慢）
  final Duration duration;

  const InlineMarquee({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(seconds: 3),
  });

  @override
  State<InlineMarquee> createState() => _InlineMarqueeState();
}

class _InlineMarqueeState extends State<InlineMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration);

  @override
  void didUpdateWidget(covariant InlineMarquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _ctrl.duration = widget.duration;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _textWidth() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        final w = _textWidth();
        if (!avail.isFinite || w <= avail) {
          // 放得下：静态一行，不跑动画
          if (_ctrl.isAnimating) _ctrl.stop();
          return Text(widget.text,
              maxLines: 1, overflow: TextOverflow.clip, style: widget.style);
        }
        final overflow = w - avail;
        if (!_ctrl.isAnimating) {
          _ctrl
            ..duration = Duration(
                milliseconds: (widget.duration.inMilliseconds *
                        (overflow / avail).clamp(0.6, 2.0))
                    .round())
            ..repeat(reverse: true);
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) => Transform.translate(
              offset: Offset(-_ctrl.value * overflow, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.text,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: widget.style),
              ),
            ),
          ),
        );
      },
    );
  }
}
