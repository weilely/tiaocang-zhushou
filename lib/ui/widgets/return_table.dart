import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../data/nav_models.dart';
import '../../logic/period_return.dart';
import 'common.dart';

/// 关注收益表：**首列与表头固定**，收益列横向滑动（与表头同步），表头点击三态排序。
///
/// 三态：未排序 → 点1 降序 ▼ → 点2 升序 ▲ → 点3 取消排序（回到传入顺序）。
/// 历史不足（`--`）的项在任何排序下都排最后。
class ReturnTable extends StatefulWidget {
  final List<WatchRow> rows;
  final void Function(WatchRow row)? onTap;
  final void Function(WatchRow row)? onMenu;

  /// 首列宽度
  ///
  /// 148dp 是留给「代码 + 完整名称」两行排布的：约 12.5 字/行，
  /// 实测最长的基金名（16~23 字）能在两行内展示，不必省略。
  final double firstWidth;

  const ReturnTable({
    super.key,
    required this.rows,
    this.onTap,
    this.onMenu,
    this.firstWidth = 148,
  });

  static const double colWidth = 86;

  /// 行高：首列正文两行约 37dp + 少量内边距 —— 按需求把行距收紧（58 → 48）
  static const double rowHeight = 48;

  /// 首列最多几行
  static const int firstColLines = 2;

  @override
  State<ReturnTable> createState() => _ReturnTableState();
}

class _ReturnTableState extends State<ReturnTable> {
  /// 首列正文样式：代码加粗、名称常规，两行合计约 37dp < 58dp 行高
  static const TextStyle _codeStyle =
      TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25);
  static const TextStyle _nameStyle = TextStyle(fontSize: 12, height: 1.25);

  /// 首列文本拟合结果缓存，键含代码 / 名称 / 可用宽度 / 字体缩放
  final Map<String, String> _nameCache = {};

  final _headerHCtrl = ScrollController();
  final _bodyHCtrl = ScrollController();
  final _leftVCtrl = ScrollController();
  final _rightVCtrl = ScrollController();

  String? _sortKey;
  bool _desc = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _bodyHCtrl.addListener(() {
      if (!_headerHCtrl.hasClients) return;
      if ((_headerHCtrl.offset - _bodyHCtrl.offset).abs() < 0.5) return;
      _headerHCtrl.jumpTo(_bodyHCtrl.offset.clamp(
        0.0,
        _headerHCtrl.position.maxScrollExtent,
      ));
    });
    _leftVCtrl.addListener(() => _syncV(_leftVCtrl, _rightVCtrl));
    _rightVCtrl.addListener(() => _syncV(_rightVCtrl, _leftVCtrl));
  }

  void _syncV(ScrollController from, ScrollController to) {
    if (_syncing || !to.hasClients || !from.hasClients) return;
    if ((to.offset - from.offset).abs() < 0.5) return;
    _syncing = true;
    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));
    _syncing = false;
  }

  @override
  void dispose() {
    _headerHCtrl.dispose();
    _bodyHCtrl.dispose();
    _leftVCtrl.dispose();
    _rightVCtrl.dispose();
    super.dispose();
  }

  // ---------------- 排序 ----------------

  double? _num(WatchRow r) {
    switch (_sortKey) {
      case 'nav':
        return r.nav;
      case null:
        return null;
      default:
        return r.returns[_sortKey];
    }
  }

  int _cmp(WatchRow a, WatchRow b) {
    int raw;
    if (_sortKey == 'code') {
      raw = a.item.code.compareTo(b.item.code);
    } else {
      final va = _num(a);
      final vb = _num(b);
      // 历史不足的恒排最后，不参与方向翻转
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      raw = va.compareTo(vb);
    }
    return _desc ? -raw : raw;
  }

  void _onHeaderTap(String key) {
    setState(() {
      if (_sortKey != key) {
        _sortKey = key;
        _desc = true;
      } else if (_desc) {
        _desc = false;
      } else {
        _sortKey = null; // 第三次：取消排序
      }
    });
  }

  List<WatchRow> get _sorted {
    if (_sortKey == null) return widget.rows;
    final list = List<WatchRow>.from(widget.rows)..sort(_cmp);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _sorted;
    final returnsWidth = ReturnTable.colWidth * 8;

    return Column(
      children: [
        // ---- 表头（垂直不滚动） ----
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.6),
            ),
          ),
          child: Row(
            children: [
              _headerCell(context, '代码名称', 'code',
                  width: widget.firstWidth, alignLeft: true),
              Expanded(
                child: SingleChildScrollView(
                  controller: _headerHCtrl,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    width: returnsWidth,
                    child: Row(
                      children: [
                        _headerCell(context, '净值', 'nav'),
                        for (final p in tablePeriods)
                          _headerCell(context, p.label, p.name),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // ---- 数据区 ----
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text('还没有关注的标的',
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).hintColor)),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: widget.firstWidth,
                      child: ListView.builder(
                        controller: _leftVCtrl,
                        itemExtent: ReturnTable.rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (_, i) => _firstCell(context, rows[i]),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _bodyHCtrl,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: returnsWidth,
                          child: ListView.builder(
                            controller: _rightVCtrl,
                            itemExtent: ReturnTable.rowHeight,
                            itemCount: rows.length,
                            itemBuilder: (_, i) => _returnCells(context, rows[i]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 表头单元格
  ///
  /// **必须显式定宽**（默认 [ReturnTable.colWidth]，首列传 `firstWidth`）：
  /// 若不设宽度，表头在父 Row 里只会占到文字自身的宽度，于是一列列紧贴着排，
  /// 与下方固定宽度居中的数据格**逐列累积错位**——越往右偏得越多。
  ///
  /// 排序箭头用 `Positioned` 绝对定位，不参与文字宽度，因此点表头排序时
  /// **标签不会左右跳动**。
  ///
  /// [alignLeft] 供「代码名称」列使用：那列的数据是左对齐的，表头必须跟着左对齐、
  /// 且左右内边距与数据格一致（8），两者左边缘才能严格对齐。
  Widget _headerCell(
    BuildContext context,
    String label,
    String key, {
    double? width,
    bool alignLeft = false,
  }) {
    final active = _sortKey == key;
    final pad = alignLeft ? 8.0 : 11.0;
    return SizedBox(
      width: width ?? ReturnTable.colWidth,
      height: 34,
      child: InkWell(
        onTap: () => _onHeaderTap(key),
        child: Stack(
          alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).hintColor,
                ),
              ),
            ),
            if (active)
              Positioned(
                right: 0,
                child: Text(
                  _desc ? '▼' : '▲',
                  style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 首列：**代码 + 完整名称合成一段文本、按单元格宽度自动换行、左对齐**
  ///
  /// 名称不预先缩写，而是先按真实宽度测量：放得下就完整显示；放不下才从中间省略，
  /// 且**保留名称最后一个字符**（份额类别 A/C/E/I）。详见 [fitName]。
  ///
  /// 左对齐的依据：这一列是「标识」，长短参差的名称左对齐才好扫读；
  /// 数值列（净值、各区间收益）仍保持居中。
  Widget _firstCell(BuildContext context, WatchRow r) {
    final base = DefaultTextStyle.of(context).style;
    final codeStyle = base.merge(_codeStyle);
    final nameStyle = base.merge(_nameStyle);
    final scale = MediaQuery.textScalerOf(context);

    // 左右各 8 的内边距
    final avail = widget.firstWidth - 16;

    InlineSpan spanFor(String part) => TextSpan(
          children: [
            TextSpan(text: r.item.code, style: codeStyle),
            if (part.isNotEmpty) TextSpan(text: ' $part', style: nameStyle),
          ],
        );

    final fitted = _fittedName(r, spanFor, avail, scale);

    return InkWell(
      onTap: () => widget.onTap?.call(r),
      onLongPress: () => widget.onMenu?.call(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            // 与测量时用的是同一棵 span 树，所见即所测
            spanFor(fitted),
            textAlign: TextAlign.left,
            softWrap: true,
            maxLines: ReturnTable.firstColLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// 带缓存的名称拟合：滚动时同一行不会反复做文字排版
  String _fittedName(
    WatchRow r,
    InlineSpan Function(String part) spanFor,
    double avail,
    TextScaler scale,
  ) {
    if (r.item.name.trim().isEmpty) return '';
    final key = '${r.item.code}|${r.item.name}|$avail|${scale.scale(1)}';
    final hit = _nameCache[key];
    if (hit != null) return hit;

    if (_nameCache.length > 200) _nameCache.clear();
    final v = fitName(
      name: r.item.name,
      maxLines: ReturnTable.firstColLines,
      maxWidth: avail,
      textScaler: scale,
      spanBuilder: spanFor,
    );
    _nameCache[key] = v;
    return v;
  }

  Widget _returnCells(BuildContext context, WatchRow r) {
    return Row(
      children: [
        _navCell(context, r),
        for (final p in tablePeriods)
          _cell(context, formatReturnPct(r.returns[p.name]),
              r.returns[p.name]),
      ],
    );
  }

  /// 净值列：**净值在上、净值日期在下**（`MM-dd`）
  ///
  /// 只显示净值的话看不出它是哪天的（场外基金 T+1 才公布，周末还停更），
  /// 日期能让「这个净值是哪天的」一眼可辨。没有净值数据时只显示 `--`，
  /// 不留一个空的日期行。
  Widget _navCell(BuildContext context, WatchRow r) {
    final theme = Theme.of(context);
    final date = fmtIsoMonthDay(r.navDate);
    return SizedBox(
      width: ReturnTable.colWidth,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            r.nav == null ? '--' : fmtPrice(r.nav!),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: r.nav == null ? theme.hintColor : null,
            ),
          ),
          if (date.isNotEmpty)
            Text(
              date,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: theme.hintColor, height: 1.2),
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, String text, double? pct) {
    return SizedBox(
      width: ReturnTable.colWidth,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: pct == null ? FontWeight.w400 : FontWeight.w500,
            color: pct == null ? Theme.of(context).hintColor : pnlColor(pct),
          ),
        ),
      ),
    );
  }
}

/// 把「代码 + 名称」压进 [maxWidth] 宽、[maxLines] 行的范围里，返回**名称片段**。
///
/// 名称放不下时，从中间省略成 `前N字…末字符`，但**必须保留最后一个字符**：
/// 末字符通常是份额类别（A / C / E / I），同一只基金的不同份额全靠它区分，
/// 一刀切掉尾巴会出现两只不同基金显示成一模一样的情况。
///
/// 按 rune（码点）切分，不会把中文或代理对截成半个字符。
///
/// 测量与渲染共用 [spanBuilder] 生成的同一棵 [InlineSpan] 树，
/// 所以「判定放得下」和「真的画出来」永远一致，不会出现判定通过却仍然溢出。
///
/// 返回 `''` 表示名称为空（此时只需显示代码）；
/// 连 `…末字符` 都放不下时**原样返回名称**，由 `TextOverflow.ellipsis` 兜底。
String fitName({
  required String name,
  required int maxLines,
  required double maxWidth,
  required TextScaler textScaler,
  required InlineSpan Function(String namePart) spanBuilder,
}) {
  final n = name.trim();
  if (n.isEmpty || maxWidth <= 0) return '';

  bool fits(String part) {
    final tp = TextPainter(
      text: spanBuilder(part),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    return !tp.didExceedMaxLines;
  }

  if (fits(n)) return n;

  final runes = n.runes.toList();
  final tail = String.fromCharCode(runes.last);
  final head = runes.sublist(0, runes.length - 1);

  // 二分出「还能再保留几个首部字符」
  var lo = 0;
  var hi = head.length;
  var best = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    final candidate = '${String.fromCharCodes(head.take(mid))}…$tail';
    if (fits(candidate)) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }

  if (best < 0) return n;
  return '${String.fromCharCodes(head.take(best))}…$tail';
}
