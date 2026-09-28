import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/index_board.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// **低估榜**：一眼看出哪些指数低估（2026-09-29 用户口径）。
///
/// 用户原话：「**我就想看哪些指数低估**」+「**按 PE 分位升序、低估在前，列里带上股息率**」。
///
/// 与「查指数」页的分工：这里**不看单个指数，只看排名**（结论式）；
/// 想查某个具体指数（搜索/分类/对比）走入口里的「查指数」那一页。
class IndexBoardPage extends StatefulWidget {
  /// 取榜单（默认 `AppState.loadIndexBoard`；测试注入）
  final Future<List<IndexBoardEntry>> Function({bool force})? boardLoader;

  /// 榜单的数据时间（测试注入；默认读 AppState）
  final DateTime? dataAt;

  const IndexBoardPage({super.key, this.boardLoader, this.dataAt});

  @override
  State<IndexBoardPage> createState() => _IndexBoardPageState();
}

class _IndexBoardPageState extends State<IndexBoardPage> {
  List<IndexBoardEntry> _rows = const [];
  bool _loading = false;
  String? _error;
  DateTime? _at;
  BoardSort _sort = BoardSort.pePercentile;
  bool? _desc; // null = 用该字段默认方向（分位/PE 从小到大，股息率从大到小）

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

  /// 刷新（带进度）：真实源走 AppState
  Future<void> _refresh() async {
    if (_injected) return _load(force: true);
    final st = context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    // 进度靠 AppState 的 notifyListeners + watch 拿，这里只等结果
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
    final theme = Theme.of(context);
    // 进度只有真实源有（AppState 每拉一批就 notify），测试注入时给空
    final progress =
        _injected ? '' : context.watch<AppState>().indexBoardProgress;
    final rows = sortBoard(_rows, _sort, desc: _desc);
    final undervalued = rows.where((r) => r.zone == '低估').length;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('低估榜'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _headCard(context, rows.length, undervalued, progress),
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
                '低估榜的成员是蛋卷收录的 ${kIndexBoardSeeds.length} 个指数；'
                '一个都没取到时这里会是空的 —— 点右上角刷新试试。',
                style: TextStyle(fontSize: 12.5, color: theme.hintColor),
              ),
            )
          else
            SectionCard(
              title: '指数估值排名',
              trailing: Text(
                _at == null ? '' : '数据 ${fmtDate(_at!)}',
                style: TextStyle(fontSize: 10.5, color: theme.hintColor),
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
      ),
    );
  }

  Widget _headCard(BuildContext context, int n, int low, String progress) {
    final theme = Theme.of(context);
    final total = kIndexBoardSeeds.length;
    final missing = _rows.where((r) => r.missing).length;
    return SectionCard(
      title: '哪些指数低估',
      trailing: _loading
          ? Text(progress.isEmpty ? '刷新中…' : '刷新中 $progress',
              style: TextStyle(fontSize: 11, color: theme.hintColor))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading) ...[
            LinearProgressIndicator(
              value: progress.isEmpty
                  ? null
                  : (double.tryParse(progress.split('/').first) ?? 0) / total,
            ),
            const SizedBox(height: 8),
          ],
          // 首次加载时**别显示"0 个低估"**（那时一条都还没取回来，会让人以为真没有）
          if (_loading && _rows.isEmpty)
            Text(
              '正在取 ${kIndexBoardSeeds.length} 个指数的估值'
              '${progress.isEmpty ? '' : '（$progress）'}…',
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
              const TextSpan(
                  text: ' 个指数处在低估区（共 ', style: TextStyle(fontSize: 12.5)),
              TextSpan(text: '$n', style: const TextStyle(fontSize: 12.5)),
              const TextSpan(text: ' 个有数据', style: TextStyle(fontSize: 12.5)),
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
    final v = r.v;
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
              '${r.code} · ${v?.symbol ?? r.symbol}'
              '${r.date.isEmpty ? '' : ' · ${v!.date}'}',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(ctx).hintColor),
            ),
            const Divider(height: 18),
            _kv(ctx, '股息率（指数成分股口径）',
                r.dividend == null ? '--' : fmtRatioPct(r.dividend!, digits: 2)),
            _kv(ctx, 'PE 历史分位', r.pePct == null ? '--' : fmtRatioPct(r.pePct!, digits: 2)),
            _kv(ctx, 'PB 历史分位', r.pbPct == null ? '--' : fmtRatioPct(r.pbPct!, digits: 2)),
            _kv(ctx, '市盈率 PE', r.pe == null ? '--' : r.pe!.toStringAsFixed(2)),
            _kv(ctx, '市净率 PB', r.pb == null ? '--' : r.pb!.toStringAsFixed(2)),
            _kv(ctx, '净资产收益率 ROE',
                r.roe == null ? '--' : fmtRatioPct(r.roe!, digits: 2)),
            const SizedBox(height: 8),
            Text(
              '数据源：蛋卷指数估值（公开接口）；分位窗口起点 '
              '${v?.windowStart == null ? '未给出' : fmtDate(v!.windowStart!)}。',
              style: TextStyle(
                  fontSize: 11, color: Theme.of(ctx).hintColor),
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
        '成员：蛋卷收录的 ${kIndexBoardSeeds.length} 个指数（宽基 / 红利 / 行业主题都有）。\n'
        '「低估 / 适中 / 高估」按 PE 历史分位划（<30% / 30%~70% / >70%），'
        '分位窗口由数据源给出（约 10 年）。\n'
        '股息率是指数成分股的分红口径，不是某只基金分红给你的比例；'
        '股息率高不等于低估（实测中证红利股息率 4.26% 但 PE 分位 79%），'
        '所以这里按分位排名、股息率只作参考。',
        style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
      );
}
