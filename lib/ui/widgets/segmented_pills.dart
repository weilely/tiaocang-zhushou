import 'package:flutter/material.dart';

/// 分段控件与筹码组的统一样式（对齐 `pic/23.jpg`、`pic/24.jpg`）
///
/// 设计稿里这一类控件都是同一套语言：
/// **一圈浅灰圆角容器 + 选中项是白底蓝字的胶囊**，未选中项是纯灰字、**不带边框**。
/// 之前我用的是「蓝色描边框」和「每个筹码各自白底细边框」，与设计稿不一致。
///
/// 容器底色取 `onSurface` 的低透明度而不是写死灰色，深色主题下才自然。
Color pillTrackColor(ThemeData theme) =>
    theme.colorScheme.onSurface.withValues(alpha: 0.06);

/// 选中项的白色胶囊底 —— 与卡片同色，看起来像「浮」在灰轨道上
Color pillThumbColor(ThemeData theme) => theme.cardColor;

/// 等分或贴合内容的分段控件
///
/// - [expand] 为真：各项等分占满整行（设计稿的 `日收益｜月收益｜年收益`）
/// - [expand] 为假：容器贴合内容宽度（设计稿右上角的 `日历图｜趋势图`）
class SegmentedPills<T> extends StatelessWidget {
  final List<({T value, String label})> items;
  final T selected;
  final ValueChanged<T> onChanged;

  /// 是否等分占满整行
  final bool expand;

  /// 单个胶囊的内边距
  final EdgeInsets itemPadding;

  const SegmentedPills({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.expand = true,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      for (final it in items) _item(theme, it.value, it.label),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: pillTrackColor(theme),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (expand)
            for (var i = 0; i < children.length; i++) ...[
              Expanded(child: children[i]),
              if (i != children.length - 1) const SizedBox(width: 3),
            ]
          else
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i != children.length - 1) const SizedBox(width: 3),
            ],
        ],
      ),
    );
  }

  Widget _item(ThemeData theme, T value, String label) {
    final on = value == selected;
    return Semantics(
      selected: on,
      button: true,
      child: Material(
        color: on ? pillThumbColor(theme) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        elevation: on ? 0.5 : 0,
        shadowColor: Colors.black26,
        child: InkWell(
          // 整段可点，不只是文字
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            alignment: Alignment.center,
            padding: itemPadding,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                color: on ? theme.colorScheme.primary : theme.hintColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 筹码组：**所有筹码共用一个浅灰圆角容器**，内部换行，选中项白底蓝字胶囊
///
/// 设计稿的区间选择就是这样：`当月 近3月 近6月 今年` / `全部 更多` 两行都在同一个灰框里，
/// 未选中的筹码没有各自的边框。
class PillGroup extends StatelessWidget {
  final List<({String label, bool selected, VoidCallback onTap})> items;

  const PillGroup({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: pillTrackColor(theme),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final it in items)
            Material(
              color: it.selected ? pillThumbColor(theme) : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              elevation: it.selected ? 0.5 : 0,
              shadowColor: Colors.black26,
              child: InkWell(
                onTap: it.onTap,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    it.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          it.selected ? FontWeight.w600 : FontWeight.w400,
                      color: it.selected
                          ? theme.colorScheme.primary
                          : theme.hintColor,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 设计稿里「月份导航」两侧的圆角方形浅灰按钮
class SquareIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const SquareIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled
            ? pillTrackColor(theme)
            : pillTrackColor(theme).withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              icon,
              size: 20,
              color: enabled ? theme.colorScheme.onSurface : theme.disabledColor,
            ),
          ),
        ),
      ),
    );
  }
}
