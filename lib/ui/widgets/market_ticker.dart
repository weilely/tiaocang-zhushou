import 'package:flutter/material.dart';

import '../../data/nav_models.dart';

/// 大盘指数跑马灯：自动横向循环滚动，不依赖任何第三方包
class MarketTicker extends StatefulWidget {
  final List<IndexQuote> quotes;
  final double height;

  const MarketTicker({super.key, required this.quotes, this.height = 32});

  /// 每个指数的固定宽度（便于无缝循环的计算）
  static const double itemWidth = 168;

  @override
  State<MarketTicker> createState() => _MarketTickerState();
}

class _MarketTickerState extends State<MarketTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _duration());
    _restart();
  }

  @override
  void didUpdateWidget(covariant MarketTicker old) {
    super.didUpdateWidget(old);
    if (old.quotes.length != widget.quotes.length ||
        old.quotes.map((e) => e.code).join() !=
            widget.quotes.map((e) => e.code).join()) {
      _restart();
    }
  }

  /// 内容越长给的时间越多，速度保持一致
  Duration _duration() {
    final n = widget.quotes.isEmpty ? 1 : widget.quotes.length;
    final total = n * MarketTicker.itemWidth;
    final ms = (total * 45).round().clamp(6000, 90000);
    return Duration(milliseconds: ms);
  }

  void _restart() {
    _ctrl.stop();
    _ctrl.duration = _duration();
    if (widget.quotes.length > 1) {
      _ctrl.repeat();
    } else {
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.quotes.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text('大盘行情暂不可用',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        ),
      );
    }

    final n = widget.quotes.length;
    final total = n * MarketTicker.itemWidth;

    return SizedBox(
      height: widget.height,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => Transform.translate(
            offset: Offset(-_ctrl.value * total, 0),
            child: Row(
              children: [
                for (final q in widget.quotes) _chip(context, q),
                // 复制一份做无缝衔接
                for (final q in widget.quotes) _chip(context, q),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, IndexQuote q) {
    final color = q.changePct > 0
        ? const Color(0xFFD93A3A)
        : (q.changePct < 0 ? const Color(0xFF1A9C5B) : Theme.of(context).hintColor);
    return SizedBox(
      width: MarketTicker.itemWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(q.name,
              style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
          const SizedBox(width: 6),
          Text(q.price.toStringAsFixed(q.priceDigits),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text(
            '${q.changePct >= 0 ? '+' : ''}${q.changePct.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
