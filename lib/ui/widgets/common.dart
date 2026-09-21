import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/db.dart';

import '../../logic/portfolio.dart';

/// 图表配色
const List<Color> kPalette = [
  Color(0xFF1F6FEB),
  Color(0xFFEF7C2E),
  Color(0xFF2E9E6B),
  Color(0xFFD94F70),
  Color(0xFF8A5CD6),
  Color(0xFF3AA6C9),
  Color(0xFFC9A227),
  Color(0xFF7A8B99),
];

/// 涨跌颜色（A 股习惯：红涨绿跌）
Color pnlColor(double v) {
  if (v > 0) return const Color(0xFFD93A3A);
  if (v < 0) return const Color(0xFF1A9C5B);
  return const Color(0xFF6B7280);
}

/// 自绘环形图（不依赖第三方图表库）
class DonutChart extends StatelessWidget {
  final List<AllocationSlice> slices;
  final String centerLabel;
  final String centerValue;
  final double size;

  const DonutChart({
    super.key,
    required this.slices,
    this.centerLabel = '',
    this.centerValue = '',
    this.size = 176,
  });

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (a, b) => a + b.value);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _DonutPainter(slices: slices, total: total),
          ),
          if (total <= 0)
            Text('暂无数据',
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13))
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (centerLabel.isNotEmpty)
                  Text(centerLabel,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                if (centerValue.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      centerValue,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<AllocationSlice> slices;
  final double total;

  _DonutPainter({required this.slices, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const stroke = 24.0;
    final radius = math.min(size.width, size.height) / 2 - stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    if (total <= 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0xFFE5E7EB);
      canvas.drawCircle(center, radius, paint);
      return;
    }

    var start = -math.pi / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].value / total * 2 * math.pi;
      paint.color = kPalette[i % kPalette.length];
      // 留一点缝隙让扇区更清晰
      const gap = 0.012;
      canvas.drawArc(rect, start + gap, math.max(sweep - gap * 2, gap), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.total != total || old.slices.length != slices.length;
}

/// 环形图图例
class AllocationLegend extends StatelessWidget {
  final List<AllocationSlice> slices;
  final bool showAmount;

  const AllocationLegend({super.key, required this.slices, this.showAmount = true});

  @override
  Widget build(BuildContext context) {
    if (slices.isEmpty) {
      return Text('暂无持仓', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13));
    }
    return Column(
      children: [
        for (var i = 0; i < slices.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: kPalette[i % kPalette.length],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    slices[i].label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                // 名称被省略号截断时也要和百分比分开，不然会连成「…100ET3.0%」
                const SizedBox(width: 10),
                Text(
                  '${(slices[i].ratio * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (showAmount) ...[
                  const SizedBox(width: 10),
                  Text(
                    _compact(slices[i].value),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  static String _compact(double v) {
    final a = v.abs();
    if (a >= 1e8) return '${(v / 1e8).toStringAsFixed(2)}亿';
    if (a >= 1e4) return '${(v / 1e4).toStringAsFixed(2)}万';
    return v.toStringAsFixed(0);
  }
}

/// 指标卡片
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final String? sub;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: valueColor,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub!, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        ],
      ],
    );
  }
}

/// 带标题的卡片容器
class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// 可折叠的卡片：点标题展开 / 收起
///
/// 设置页那些长卡片（调仓目标、数据维护中心）可以收起，一屏能看到更多入口。
/// [trailing] 上的按钮不参与折叠（点它只做它自己的事）。
class CollapsibleSectionCard extends StatefulWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool initiallyExpanded;
  final EdgeInsets padding;

  /// 展开时在内容**底部**再给一个「收起」按钮
  ///
  /// 内容长的卡片（数据维护中心、行情指标）展开后，顶部的收起箭头会被滚出屏幕，
  /// 用户反映"进了卡片出不来" —— 底部留个出口。
  final bool showCollapseAtBottom;

  /// 折叠状态持久化用的键；不传就按标题（去掉「（2）」这种计数）自动取
  final String? storageKey;

  const CollapsibleSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.initiallyExpanded = true,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 16),
    this.storageKey,
    this.showCollapseAtBottom = false,
  });

  @override
  State<CollapsibleSectionCard> createState() => _CollapsibleSectionCardState();
}

class _CollapsibleSectionCardState extends State<CollapsibleSectionCard> {
  late bool _open = widget.initiallyExpanded;

  /// 折叠记忆的键：`card:账户管理`（标题里的「（2）」这类计数不算）
  ///
  /// 早先这个 getter 里标题那一段丢了（`'card:'`），于是**所有没传 storageKey
  /// 的卡片共用同一个键** —— 收起一张，重启后别的卡片也跟着变。
  String get _key => widget.storageKey ??
      'card:${widget.title.replaceAll(RegExp(r'（\d+）'), '').trim()}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// 读回上次的折叠状态（读不到就用默认值）
  Future<void> _restore() async {
    try {
      final v = await AppDatabase.instance.setting(_key);
      if (!mounted || v == null) return;
      final open = v == '1';
      if (open != _open) setState(() => _open = open);
    } catch (_) {
      // 读不到就按默认
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    // 存起来，下次启动保持不变
    AppDatabase.instance.setSetting(_key, _open ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          widget.padding.left,
          widget.padding.top + 10,
          widget.padding.right,
          _open ? widget.padding.bottom : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _toggle,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(_open ? Icons.expand_more : Icons.chevron_right,
                              size: 20, color: theme.hintColor),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(widget.title,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
            if (_open) ...[
              const SizedBox(height: 6),
              widget.child,
              // 卡片内容一长，顶部的收起箭头就滚出屏幕了 —— 底部再给一个出口，
              // 免得"进了卡片出不来"
              if (widget.showCollapseAtBottom) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: _toggle,
                    icon: const Icon(Icons.expand_less, size: 18),
                    label: const Text('收起'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.hintColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 全局统一的圆角：**和关注页的基金搜索框一致**
///
/// 用户要求「所有带边框的圆角样式都和基金搜索框一样」，所以把半径收到一处，
/// 别再各处写 8/10/12/24 各一套。
const double kBoxRadius = 10;

/// 统一边框色 —— 搜索框用的是 `OutlineInputBorder` 默认色，即 `colorScheme.outline`
Color boxBorderColor(BuildContext context) =>
    Theme.of(context).colorScheme.outline;

/// 统一的「带边框圆角盒子」（细边框、不填充）
BoxDecoration boxOutlineDecoration(BuildContext context,
        {bool selected = false, Color? selectedColor}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(kBoxRadius),
      border: Border.all(
        color: selected
            ? (selectedColor ?? Theme.of(context).colorScheme.primary)
            : boxBorderColor(context),
      ),
    );

/// 统一的输入框装饰：细边框 + 圆角 10（与搜索框同一套）
///
/// 取代原先那种"填充色块、没有边框"的写法 —— 和搜索框摆在一起时明显两套风格。
InputDecoration boxInputDecoration(BuildContext context) {
  final r = BorderRadius.circular(kBoxRadius);
  final side = BorderSide(color: boxBorderColor(context));
  return InputDecoration(
    isDense: true,
    border: OutlineInputBorder(borderRadius: r, borderSide: side),
    enabledBorder: OutlineInputBorder(borderRadius: r, borderSide: side),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}

/// 空状态提示
class EmptyHint extends StatelessWidget {  final String text;
  final IconData icon;
  final Widget? action;

  const EmptyHint({super.key, required this.text, this.icon = Icons.inbox_outlined, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).hintColor.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 14),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
