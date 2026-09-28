import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/csi_indicator.dart';
import '../data/csi_perf.dart';
import '../data/index_catalog.dart';
import '../data/index_eva.dart';
import 'widgets/common.dart';

/// 对比表能排的列（**每一列的来源都不一样，别混**）
enum CompareSort {
  dividend('股息率'),
  pe('PE'),
  pePercentile('PE 分位'),
  pb('PB'),
  roe('ROE'),
  consNumber('成分数'),
  monthlyReturn('月度收益'),
  name('名称');

  const CompareSort(this.label);
  final String label;
}

/// **指数对比表**：把勾选的几个指数并排看，可按股息率/PE/PB/分位排序。
///
/// 用户口径：「所有指数能分类，排序对比」。
///
/// ⚠️ **诚实上限（页面上要写清，别让人以为"全都有"）**：
/// - **PE** 走中证官网 `index-perf`（`peg`）→ **中证目录里的指数基本都有**；
/// - **股息率** 优先**蛋卷**（它同时给 PB/ROE/分位），蛋卷没收录就退到
///   **中证官网 `indicator.xls`**（覆盖全部中证指数）—— 两边口径不是同一个数，
///   所以**每一行都标出股息率是谁给的**；
/// - **PB / ROE / PE 分位** 只有蛋卷收录的指数才有 → 没有的显示「暂无」，
///   **不是**"这个指数股息为 0"；
/// - **成分数 / 月度收益** 是目录自带的（中证官网）。
class IndexComparePage extends StatefulWidget {
  /// 要比的指数（来自目录勾选）
  final List<IndexCatalogItem> items;

  /// 取估值（股息率/PB/ROE/分位）；默认走 `AppState.loadIndexByCode`
  final Future<IndexValuation?> Function(String code, String? name)?
      valuationLoader;

  /// 取中证的股息率/PE（`indicator.xls`）；默认走 `AppState.loadCsiIndicator`
  final Future<CsiIndicator?> Function(String code)? indicatorLoader;

  /// 取中证 PE/点位（`index-perf`，`indicator.xls` 失败时的兜底）；
  /// 默认走 `AppState.loadCsiPe`
  final Future<CsiPerfPoint?> Function(String code)? peLoader;

  const IndexComparePage({
    super.key,
    required this.items,
    this.valuationLoader,
    this.indicatorLoader,
    this.peLoader,
  });

  @override
  State<IndexComparePage> createState() => _IndexComparePageState();
}

class _CompareRow {
  final IndexCatalogItem item;
  IndexValuation? v;
  CsiIndicator? ind;
  CsiPerfPoint? perf;

  _CompareRow(this.item);

  /// 股息率（小数）：优先蛋卷，其次中证官网 `indicator.xls`
  double? get dividend {
    final fromDanjuan = v?.yeild;
    if (fromDanjuan != null) return fromDanjuan;
    final csi = ind?.dividendYield;
    return csi == null ? null : csi / 100; // 中证给的是百分数
  }

  /// 股息率是谁给的（两边口径不同，行内要标出来）
  String get dividendSource {
    if (v?.yeild != null) return '蛋卷';
    if (ind?.dividendYield != null) return '中证';
    return '';
  }

  double? get pe => v?.pe ?? ind?.pe ?? perf?.pe;
  double? get pb => v?.pb;
  double? get roe => v?.roe;
  double? get pePercentile => v?.pePercentile;
  int? get consNumber => item.consNumber ?? perf?.consNumber;
}

class _IndexComparePageState extends State<IndexComparePage> {
  late final List<_CompareRow> _rows =
      [for (final it in widget.items) _CompareRow(it)];

  int _done = 0;
  bool _loading = true;
  CompareSort _sort = CompareSort.dividend;
  bool _desc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    for (final r in _rows) {
      // 逐个来：蛋卷要逐个猜符号，中证也要一次一个请求 —— 别并发炸人家
      try {
        r.v = await (widget.valuationLoader != null
            ? widget.valuationLoader!(r.item.code, r.item.name)
            : Future<IndexValuation?>.value(null));
      } catch (_) {
        r.v = null;
      }
      // 蛋卷没收录才去中证要股息率/PE（`indicator.xls`，覆盖全部中证指数）
      if (r.v == null) {
        try {
          r.ind = await (widget.indicatorLoader != null
              ? widget.indicatorLoader!(r.item.code)
              : Future<CsiIndicator?>.value(null));
        } catch (_) {
          r.ind = null;
        }
      }
      // 到这一步还没 PE 的，才去问 `index-perf`（多一次请求，能省则省）
      if (r.pe == null) {
        try {
          r.perf = await (widget.peLoader != null
              ? widget.peLoader!(r.item.code)
              : Future<CsiPerfPoint?>.value(null));
        } catch (_) {
          r.perf = null;
        }
      }
      if (!mounted) return;
      setState(() => _done++);
    }
    if (mounted) setState(() => _loading = false);
  }

  List<_CompareRow> get _sorted {
    double? numOf(_CompareRow r) => switch (_sort) {
          CompareSort.dividend => r.dividend,
          CompareSort.pe => r.pe,
          CompareSort.pb => r.pb,
          CompareSort.roe => r.roe,
          CompareSort.pePercentile => r.pePercentile,
          CompareSort.consNumber => r.consNumber?.toDouble(),
          CompareSort.monthlyReturn => r.item.monthlyReturn == null
              ? null
              : r.item.monthlyReturn! / 100,
          CompareSort.name => null,
        };

    final list = List.of(_rows);
    list.sort((a, b) {
      if (_sort == CompareSort.name) {
        final r = a.item.name.compareTo(b.item.name);
        return _desc ? -r : r;
      }
      final x = numOf(a), y = numOf(b);
      // **缺值永远沉底**（哪个方向都一样）：没有数据不许装成最小/最大
      if (x == null && y == null) return a.item.code.compareTo(b.item.code);
      if (x == null) return 1;
      if (y == null) return -1;
      final r = x.compareTo(y);
      if (r == 0) return a.item.code.compareTo(b.item.code);
      return _desc ? -r : r;
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final got = _rows.where((r) => r.dividend != null || r.pe != null).length;
    final danjuan = _rows.where((r) => r.dividendSource == '蛋卷').length;
    final sorted = _sorted;
    return Scaffold(
      appBar: AppBar(titleSpacing: 16, title: const Text('指数对比')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          SectionCard(
            title: '对比 ${_rows.length} 个指数',
            trailing: _loading
                ? Text('正在取 $_done/${_rows.length}',
                    style: TextStyle(fontSize: 11, color: theme.hintColor))
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loading) ...[
                  LinearProgressIndicator(
                      value: _rows.isEmpty ? null : _done / _rows.length),
                  const SizedBox(height: 8),
                ],
                Text(
                  '有数的：$got / ${_rows.length} 个指数（其中股息率来自蛋卷的有 '
                  '$danjuan 个）。\n'
                  '股息率优先蛋卷，蛋卷没收录就用中证官网（两边口径略有差别，'
                  '行内标了来源）；PB、ROE、PE 分位只有蛋卷有；PE 中证官网基本都有。',
                  style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                ),
                const SizedBox(height: 8),
                _sortBar(context),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '并排看',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _headerRow(context),
                const Divider(height: 14),
                for (final r in sorted) _dataRow(context, r),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '「暂无」= 我们的公开源里没有这个指数的这项数据（不是 0）。'
            '股息率是指数的成分股分红口径，不是某只基金分红给你的比例。\n'
            '蛋卷与中证官网算出来的股息率口径不同，可能差零点几个百分点 —— '
            '行内标了是谁给的。',
            style: TextStyle(fontSize: 10.5, color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _sortBar(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text('排序',
            style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
        const SizedBox(width: 6),
        PopupMenuButton<CompareSort>(
          tooltip: '排序字段',
          position: PopupMenuPosition.under,
          onSelected: (s) => setState(() => _sort = s),
          itemBuilder: (_) => [
            for (final s in CompareSort.values)
              PopupMenuItem(
                value: s,
                child: Row(
                  children: [
                    if (s == _sort)
                      Icon(Icons.check,
                          size: 15, color: theme.colorScheme.primary)
                    else
                      const SizedBox(width: 15),
                    const SizedBox(width: 6),
                    Text('按${s.label}',
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
          ],
          child: Text('按${_sort.label}',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: _desc ? '当前：从大到小' : '当前：从小到大',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward,
              size: 16),
          onPressed: () => setState(() => _desc = !_desc),
        ),
      ],
    );
  }

  Widget _headerRow(BuildContext context) {
    final hint = TextStyle(
        fontSize: 10.5, color: Theme.of(context).hintColor);
    return Row(
      children: [
        Expanded(flex: 34, child: Text('指数', style: hint)),
        Expanded(
            flex: 22,
            child: Text('股息率', style: hint, textAlign: TextAlign.right)),
        Expanded(
            flex: 22,
            child: Text('PE', style: hint, textAlign: TextAlign.right)),
        Expanded(
            flex: 22,
            child: Text('PB', style: hint, textAlign: TextAlign.right)),
      ],
    );
  }

  Widget _dataRow(BuildContext context, _CompareRow r) {
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    Widget cell(String text, {bool missing = false}) => Text(
          text,
          textAlign: TextAlign.right,
          style: missing
              ? TextStyle(fontSize: 11.5, color: theme.hintColor)
              : const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        );
    final div = r.dividend;
    final sub = [
      r.item.code,
      if (r.dividendSource == '中证') '股息率·中证',
      if (r.pePercentile != null)
        'PE分位 ${fmtRatioPct(r.pePercentile!, digits: 0)}',
      if (r.consNumber != null) '${r.consNumber}只',
      if (r.item.monthlyReturn != null)
        '月度 ${fmtRatioPct(r.item.monthlyReturn! / 100, digits: 2)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 34,
                child: Text(r.item.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                  flex: 22,
                  child: cell(div == null ? '暂无' : fmtRatioPct(div, digits: 2),
                      missing: div == null)),
              Expanded(
                  flex: 22,
                  child: cell(
                      r.pe == null ? '暂无' : r.pe!.toStringAsFixed(2),
                      missing: r.pe == null)),
              Expanded(
                  flex: 22,
                  child: cell(
                      r.pb == null ? '暂无' : r.pb!.toStringAsFixed(2),
                      missing: r.pb == null)),
            ],
          ),
          const SizedBox(height: 2),
          Text(sub, style: hint, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
