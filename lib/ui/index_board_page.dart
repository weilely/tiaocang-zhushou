import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/index_board.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// **低估榜**：一眼看出哪些指数低估（2026-09-29 用户口径）。
///
/// 用户原话：「**我就想看哪些指数低估**」+「**按 PE 分位升序、低估在前，列里带上股息率**」，
/// 之后又补两点：**扩大成员**（补了 9 只中证自算的）与**只看红利 / 宽基的筛选**。
///
/// 与「查指数」页的分工：这里**只看排名**（结论式）；想查某个具体指数（搜索/分类/对比）
/// 走入口里的「查指数」那一页。
/// **低估榜**（单独打开的页面壳）。
///
/// 真正的内容在 [IndexBoardView] —— 这样「指数看板」页可以把它当一个**标签页**嵌进去，
/// 单独打开时又是个正常页面（2026-09-29 用户要求把三块合成一个看板、页内用标签切换）。
class IndexBoardPage extends StatelessWidget {
  final Future<List<IndexBoardEntry>> Function({bool force})? boardLoader;
  final DateTime? dataAt;

  const IndexBoardPage({super.key, this.boardLoader, this.dataAt});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(titleSpacing: 16, title: const Text('低估榜')),
        body: IndexBoardView(boardLoader: boardLoader, dataAt: dataAt),
      );
}

/// 低估榜的**内容**（不含 Scaffold/AppBar，可直接当标签页）
class IndexBoardView extends StatefulWidget {
  /// 取榜单（默认 `AppState.loadIndexBoard`；测试注入）
  final Future<List<IndexBoardEntry>> Function({bool force})? boardLoader;

  /// 榜单的数据时间（测试注入；默认读 AppState）
  final DateTime? dataAt;

  const IndexBoardView({super.key, this.boardLoader, this.dataAt});

  @override
  State<IndexBoardView> createState() => _IndexBoardViewState();
}

class _IndexBoardViewState extends State<IndexBoardView> {
  List<IndexBoardEntry> _rows = const [];
  bool _loading = false;
  String? _error;
  DateTime? _at;
  BoardSort _sort = BoardSort.pePercentile;
  bool? _desc; // null = 用该字段默认方向（分位/PE 从小到大，股息率从大到小）
  String _kind = ''; // '' = 全部

  bool get _injected => widget.boardLoader != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    final st = _injected ? null : context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = widget.boardLoader != null
          ? await widget.boardLoader!(force: force)
          : await st!.loadIndexBoard(force: force);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _at = widget.dataAt ?? st?.indexBoardAt ?? _at;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '榜单取数失败（$e）');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 刷新（真实源走 AppState，进度靠它的 notify + watch）
  Future<void> _refresh() async {
    if (_injected) return _load(force: true);
    final st = context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    final rows = await st.loadIndexBoard(force: true);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _at = st.indexBoardAt;
      _loading = false;
      _error = st.indexBoardError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        _injected ? '' : context.watch<AppState>().indexBoardProgress;
    final filtered = _kind.isEmpty
        ? _rows
        : [for (final r in _rows) if (r.kind == _kind) r];
    final rows = sortBoard(filtered, _sort, desc: _desc);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _headCard(context, rows, progress),
        if (_error != null) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: '这份榜单没刷新成功',
            child: Text(
              '$_error\n下面是上次拿到的数据（不是今天的最新值）。',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (rows.isEmpty && !_loading)
          SectionCard(
            title: '还没拿到数据',
            child: Text(
              '低估榜的成员是蛋卷收录的 $kBoardDanjuanCount 个指数 + '
              '中证官网自算分位的 $kBoardComputedCount 个指数；'
              '一个都没取到时这里会是空的 —— 点卡头的刷新按钮试试。',
              style: TextStyle(
                  fontSize: 12.5, color: Theme.of(context).hintColor),
            ),
          )
        else
          SectionCard(
            title: _kind.isEmpty ? '指数估值排名' : '$_kind（估值排名）',
            trailing: Text(
              _at == null ? '' : '数据 ${fmtDate(_at!)}',
              style: TextStyle(
                  fontSize: 10.5, color: Theme.of(context).hintColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sortBar(context),
                const Divider(height: 14),
                for (final r in rows) _row(context, r),
              ],
            ),
          ),
        const SizedBox(height: 12),
        _footer(context),
      ],
    );
  }

  /// `'蛋卷 12/35'` / `'自算 3/9'` → 进度值（解析不了就转圈）
  double? _progressValue(String progress) {
    final parts = progress.split('/');
    if (parts.length != 2) return null;
    final done = int.tryParse(parts.first.split(' ').last);
    final total = int.tryParse(parts.last);
    if (done == null || total == null || total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }

  Widget _headCard(BuildContext context, List<IndexBoardEntry> rows,
      String progress) {
    final theme = Theme.of(context);
    final total = kIndexBoardSeeds.length;
    final low = rows.where((r) => r.zone == '低估').length;
    final missing = rows.where((r) => r.missing).length;
    final withData = rows.length - missing; // "有数据"要扣掉这次没取到的
    return SectionCard(
      title: '哪些指数低估',
      // 刷新放在卡头（这样"单独打开"和"当标签页嵌进指数看板"都够得着）
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            Text(progress.isEmpty ? '刷新中…' : '刷新中 $progress',
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
          IconButton(
            tooltip: '刷新榜单',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(value: _progressValue(progress)),
            ),
          // 首次加载时**别显示"0 个低估"**（那时一条都还没取回来，会让人以为真没有）
          if (_loading && _rows.isEmpty)
            Text(
              '正在取 $total 个指数的估值'
              '（先蛋卷 $kBoardDanjuanCount 个，再中证自算 $kBoardComputedCount 个）'
              '${progress.isEmpty ? '' : '：$progress'}…',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            )
          else
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: '$low',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary)),
              TextSpan(
                  text: _kind.isEmpty
                      ? ' 个指数处在低估区（共 $withData 个有数据'
                      : ' 个$_kind指数处在低估区（本类 $withData 个有数据',
                  style: const TextStyle(fontSize: 12.5)),
              if (missing > 0)
                TextSpan(
                    text: '，另有 $missing 个这次没取到',
                    style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
              const TextSpan(text: '）', style: TextStyle(fontSize: 12.5)),
            ])),
          const SizedBox(height: 4),
          Text(
            '低估 / 高估按 PE 历史分位划：低于 30% 算低估、高于 70% 算高估。'
            '排名默认按 PE 分位从低到高 —— 低估在前。',
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in ['', ...kBoardKinds])
                ChoiceChip(
                  label: Text(k.isEmpty ? '全部' : k,
                      style: const TextStyle(fontSize: 11.5)),
                  selected: _kind == k,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
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
        PopupMenuButton<BoardSort>(
          tooltip: '排序字段',
          position: PopupMenuPosition.under,
          onSelected: (s) => setState(() {
            _sort = s;
            _desc = null; // 换字段就回到该字段"有意思"的方向
          }),
          itemBuilder: (_) => [
            for (final s in BoardSort.values)
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
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary)),
        ),
        IconButton(
          tooltip: (_desc ?? _sort.defaultDesc) ? '当前：从大到小' : '当前：从小到大',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(
              (_desc ?? _sort.defaultDesc)
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
              size: 16),
          onPressed: () => setState(() => _desc = !(_desc ?? _sort.defaultDesc)),
        ),
      ],
    );
  }

  /// 低估绿、高估红（这里是**估值水平**，不是涨跌，别跟盈亏色混）
  static Color _zoneColor(String zone, BuildContext context) =>
      switch (zone) {
        '低估' => const Color(0xFF22C55E),
        '高估' => const Color(0xFFEF4444),
        _ => Theme.of(context).hintColor,
      };

  Widget _row(BuildContext context, IndexBoardEntry r) {
    final theme = Theme.of(context);
    final pct = r.pePct;
    final zone = r.zone;
    if (r.missing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(r.name,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            Text('这次没取到',
                style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
          ],
        ),
      );
    }
    return InkWell(
      onTap: () => _detail(context, r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(r.name,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                if (zone.isNotEmpty) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: _zoneColor(zone, context)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(zone,
                        style: TextStyle(
                            fontSize: 10,
                            color: _zoneColor(zone, context),
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(pct == null ? '--' : fmtRatioPct(pct, digits: 1),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                r.code,
                '股息率 ${r.dividend == null ? '--' : fmtRatioPct(r.dividend!, digits: 2)}',
                'PE ${r.pe == null ? '--' : r.pe!.toStringAsFixed(2)}',
                'PB ${r.pb == null ? '--' : r.pb!.toStringAsFixed(2)}',
                // 自算那批只有 PE/分位，标清来源，别让人以为是同一个口径
                if (r.symbol.isEmpty) '分位·中证自算',
              ].join(' · '),
              style: TextStyle(fontSize: 10.5, color: theme.hintColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _detail(BuildContext context, IndexBoardEntry r) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (r.zone.isNotEmpty)
                  Text(r.zone,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _zoneColor(r.zone, ctx))),
              ],
            ),
            Text(
              '${r.code}${r.kind.isEmpty ? '' : ' · ${r.kind}'}'
              '${r.date.isEmpty ? '' : ' · ${r.date}'}',
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
            const Divider(height: 18),
            _kv(ctx, '股息率（指数成分股口径）',
                r.dividend == null ? '--' : fmtRatioPct(r.dividend!, digits: 2)),
            _kv(ctx, 'PE 历史分位',
                r.pePct == null ? '--' : fmtRatioPct(r.pePct!, digits: 2)),
            _kv(ctx, 'PB 历史分位',
                r.pbPct == null ? '--' : fmtRatioPct(r.pbPct!, digits: 2)),
            _kv(ctx, '市盈率 PE',
                r.pe == null ? '--' : r.pe!.toStringAsFixed(2)),
            _kv(ctx, '市净率 PB',
                r.pb == null ? '--' : r.pb!.toStringAsFixed(2)),
            _kv(ctx, '净资产收益率 ROE',
                r.roe == null ? '--' : fmtRatioPct(r.roe!, digits: 2)),
            const SizedBox(height: 8),
            Text(
              r.symbol.isEmpty
                  ? '数据源：中证指数官网 PE 历史，分位是自己算的'
                      '（最新 PE 在 ${r.windowStart.isEmpty ? '这段历史' : '${r.windowStart} 起'}'
                      ' ${r.samples} 个交易日里的位置）；这一路没有股息率/PB/ROE。'
                  : '数据源：蛋卷指数估值（公开接口）；'
                      '分位窗口起点 ${r.windowStart.isEmpty ? '未给出' : r.windowStart}。',
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5, color: Theme.of(context).hintColor)),
            ),
            Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _footer(BuildContext context) => Text(
        '成员 ${kIndexBoardSeeds.length} 个：蛋卷收录的 $kBoardDanjuanCount 个'
        '（宽基 / 红利 / 行业主题都有）+ 中证官网自算分位的 $kBoardComputedCount 个'
        '（上证指数、中证A500、科创100、北证50、中证全指、中证A50、红利质量、'
        '全指红利质量、红利价值）。\n'
        '「低估 / 适中 / 高估」按 PE 历史分位划（<30% / 30%~70% / >70%）。'
        '两个源的分位窗口不同（蛋卷约 10 年、中证自算是它给的全段历史），'
        '方向一致但数值会有差，行内标了是谁给的。\n'
        '股息率是指数成分股的分红口径，不是某只基金分红给你的比例；'
        '股息率高不等于低估（实测中证红利股息率 4.26% 但 PE 分位 79%），'
        '所以这里按分位排名、股息率只作参考。',
        style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
      );
}
