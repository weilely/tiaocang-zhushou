import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/index_catalog.dart';
import '../data/index_eva.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 列表一次显示多少条（滚到底/点「显示更多」再加一页）
const int kIndexListPage = 60;

/// **指数估值 / 指数查询**通用页（2026-09-29 改成通用模版）。
///
/// 用户口径：「我想要的是通用模版，**不针对个人偏好**，想查哪个就能查哪个，
/// 或者所有指数能分类，排序对比」→ 所以撤掉了原来那份"照着他持仓挑的常用指数"，
/// 入口换成**中证指数官网的官方全量指数表**（3001 条，见 `data/index_catalog.dart`）：
/// 本地搜索任意指数 + 分类筛选 + 排序，点开看该指数的估值。
///
/// 数据分工（**都不许含糊**）：
/// ①**目录**（代码/名称/系列/资产类别/分类/地区/币种/成分数/点位/月度收益/发布日）
///   来自中证官网，全本地筛选排序 → 离线可用；
/// ②**估值**（股息率/PE/PB/ROE/分位）来自蛋卷公开接口，**收录范围有限**：
///   查不到就如实说"暂无数据源"，绝不拿别的指数顶替；蛋卷的名字与目录不一致时
///   两个名字都显示出来（规矩：拿不准就别编）。
class IndexValuationPage extends StatefulWidget {
  /// 搜索函数（默认走 `AppState.searchIndexes`，东财联想）
  final Future<List<IndexCandidate>> Function(String query)? searchLoader;

  /// 按**蛋卷符号**取估值（默认 `AppState.loadIndexValuation`）——最近查过用
  final Future<IndexValuation?> Function(String symbol)? symbolLoader;

  /// 按**搜索候选**取估值（默认 `AppState.loadIndexCandidate`）
  final Future<IndexValuation?> Function(IndexCandidate c)? candidateLoader;

  /// 取指数目录（默认 `AppState.loadIndexCatalog`）
  final Future<IndexCatalog?> Function()? catalogLoader;

  /// 按**目录代码**取估值（默认 `AppState.loadIndexByCode`）
  final Future<IndexValuation?> Function(String code, String? name)? codeLoader;

  const IndexValuationPage({
    super.key,
    this.searchLoader,
    this.symbolLoader,
    this.candidateLoader,
    this.catalogLoader,
    this.codeLoader,
  });

  @override
  State<IndexValuationPage> createState() => _IndexValuationPageState();
}

class _IndexValuationPageState extends State<IndexValuationPage> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  // ── 目录 ────────────────────────────────────────────────────────────────
  IndexCatalog? _catalog;
  bool _catalogLoading = false;
  String _catalogProgress = '';
  String? _catalogError;

  // ── 本地查询条件 ─────────────────────────────────────────────────────────
  String _keyword = '';
  String _series = '';
  String _classify = '';
  String _assetClass = '';
  bool _trackedOnly = false;
  IndexSortField _sort = IndexSortField.code;
  bool _desc = false;
  int _limit = kIndexListPage;

  /// 本地没命中时用东财联想兜底（国证/恒生这些**不在中证目录里**的指数）
  List<IndexCandidate> _remote = const [];
  bool _remoteSearching = false;
  String _remoteFor = '';

  // ── 估值 ────────────────────────────────────────────────────────────────
  IndexValuation? _current;
  bool _loadingValue = false;
  String _pendingName = '';
  String? _missName;
  bool _missIsNetwork = false;

  /// 蛋卷返回的名字与目录不一致时留一份对照（两个都显示）
  String _askedName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalog());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── 目录 ────────────────────────────────────────────────────────────────

  Future<void> _loadCatalog({bool force = false}) async {
    if (_catalogLoading) return;
    if (_catalog != null && !force) return;
    // await 之前先拿到状态对象（用 buildContext 跨 await 会被 lint 拦）
    final st = widget.catalogLoader == null ? context.read<AppState>() : null;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
      _catalogProgress = '';
    });
    try {
      final c = widget.catalogLoader != null
          ? await widget.catalogLoader!()
          : await st!.loadIndexCatalog(
              force: force,
              onProgress: (done, total) {
                if (!mounted) return;
                setState(() => _catalogProgress = '$done/$total');
              },
            );
      if (!mounted) return;
      setState(() {
        if (c != null) _catalog = c;
        _catalogError = c == null ? (st?.indexCatalogError ?? '目录没取到') : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _catalogError = '目录取数失败（$e）');
    } finally {
      if (mounted) setState(() => _catalogLoading = false);
    }
  }

  // ── 查询 ────────────────────────────────────────────────────────────────

  List<IndexCatalogItem> get _hits {
    final c = _catalog;
    if (c == null) return const [];
    return c.query(
      keyword: _keyword,
      series: _series.isEmpty ? const {} : {_series},
      classifies: _classify.isEmpty ? const {} : {_classify},
      assetClasses: _assetClass.isEmpty ? const {} : {_assetClass},
      trackedOnly: _trackedOnly,
      sort: _sort,
      desc: _desc,
    );
  }

  void _onQueryChanged(String raw) {
    final q = raw.trim();
    setState(() {
      _keyword = q;
      _limit = kIndexListPage;
      _remote = const [];
      _remoteFor = '';
      _remoteSearching = false;
    });
    _debounce?.cancel();
    if (q.isEmpty) return;
    // 本地目录（3001 条）秒出；**本地没命中**才去问东财联想 ——
    // 国证系、恒生系这些不在中证目录里，但用户可能就是要查它们。
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final localHit = _hits.isNotEmpty;
      if (localHit) return;
      _runRemoteSearch(q);
    });
  }

  Future<void> _runRemoteSearch(String q) async {
    setState(() {
      _remoteSearching = true;
      _remoteFor = q;
    });
    List<IndexCandidate> list;
    try {
      final loader = widget.searchLoader;
      list = loader != null
          ? await loader(q)
          : await context.read<AppState>().searchIndexes(q);
    } catch (_) {
      list = const [];
    }
    if (!mounted || _remoteFor != q) return;
    setState(() {
      _remote = list;
      _remoteSearching = false;
    });
  }

  void _resetFilters() => setState(() {
        _keyword = '';
        _query.clear();
        _series = '';
        _classify = '';
        _assetClass = '';
        _trackedOnly = false;
        _limit = kIndexListPage;
        _remote = const [];
        _remoteFor = '';
      });

  // ── 取估值 ───────────────────────────────────────────────────────────────

  void _beginLoad(String label) => setState(() {
        _loadingValue = true;
        _current = null;
        _missName = null;
        _missIsNetwork = false;
        _pendingName = label;
        _askedName = label;
      });

  void _finishLoad(IndexValuation? v, {required bool netFail, required String label}) {
    if (!mounted) return;
    setState(() {
      _current = v;
      _loadingValue = false;
      _pendingName = '';
      if (v == null) {
        _missName = label;
        _missIsNetwork = netFail;
      }
    });
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  /// 点目录里的某条 → 取估值
  Future<void> _fetchByItem(IndexCatalogItem it) async {
    _beginLoad(it.name);
    IndexValuation? v;
    var netFail = false;
    try {
      final loader = widget.codeLoader;
      if (loader != null) {
        v = await loader(it.code, it.name);
      } else {
        final st = context.read<AppState>();
        v = await st.loadIndexByCode(it.code, name: it.name);
      }
    } catch (_) {
      netFail = true;
    }
    _finishLoad(v, netFail: netFail, label: it.name);
  }

  /// 点东财联想的候选 → 取估值
  Future<void> _fetchByCandidate(IndexCandidate c) async {
    _beginLoad(c.name);
    IndexValuation? v;
    var netFail = false;
    try {
      final loader = widget.candidateLoader;
      if (loader != null) {
        v = await loader(c);
      } else {
        final st = context.read<AppState>();
        v = await st.loadIndexCandidate(c);
      }
    } catch (_) {
      netFail = true;
    }
    _finishLoad(v, netFail: netFail, label: c.name);
  }

  /// 点「最近查过」→ 按蛋卷符号直接取（已经知道符号了）
  Future<void> _fetchBySymbol(String symbol, String label) async {
    _beginLoad(label);
    IndexValuation? v;
    var netFail = false;
    try {
      final loader = widget.symbolLoader;
      if (loader != null) {
        v = await loader(symbol);
      } else {
        final st = context.read<AppState>();
        v = await st.loadIndexValuation(symbol);
      }
    } catch (_) {
      netFail = true;
    }
    _finishLoad(v, netFail: netFail, label: label);
  }

  /// 只读 Provider（没注入 loader 时才是真实数据源；测试里全注入）
  bool get _injected =>
      widget.catalogLoader != null &&
      widget.searchLoader != null &&
      widget.symbolLoader != null &&
      widget.candidateLoader != null &&
      widget.codeLoader != null;

  // ── 界面 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final recent = _injected
        ? const <IndexValuation>[]
        : context.watch<AppState>().recentIndexValuations;
    final hits = _hits;
    final shown = hits.length > _limit ? hits.sublist(0, _limit) : hits;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('指数估值'),
        actions: [
          IconButton(
            tooltip: '刷新指数目录',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _catalogLoading ? null : () => _loadCatalog(force: true),
          ),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _searchCard(context, hits.length),
          const SizedBox(height: 12),
          if (_catalogLoading) _loadingCard(context),
          if (_catalogError != null) _errorCard(context),
          if (_loadingValue)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  if (_pendingName.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('正在取「$_pendingName」的估值…',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).hintColor)),
                  ],
                ],
              ),
            )
          else if (_current != null)
            _valuationCard(context, _current!)
          else if (_missName != null)
            _missCard(context),
          if (hits.isNotEmpty || _remote.isNotEmpty || _remoteSearching) ...[
            const SizedBox(height: 12),
            _filterCard(context),
            const SizedBox(height: 12),
            _resultCard(context, hits, shown),
          ],
          if (_remote.isNotEmpty || _remoteSearching) ...[
            const SizedBox(height: 12),
            _remoteCard(context),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            _recentCard(context, recent),
          ],
          const SizedBox(height: 12),
          _footer(context),
        ],
      ),
    );
  }

  Widget _searchCard(BuildContext context, int hitCount) {
    final theme = Theme.of(context);
    final cat = _catalog;
    return SectionCard(
      title: '查指数',
      trailing: cat == null
          ? null
          : Text('共 ${cat.items.length} 条 · 命中 $hitCount',
              style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _query,
            onChanged: _onQueryChanged,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '代码或名称，如「红利」「000922」',
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
            ),
          ),
          if (_keyword.isNotEmpty || _series.isNotEmpty ||
              _classify.isNotEmpty || _assetClass.isNotEmpty ||
              _trackedOnly)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        if (_keyword.isNotEmpty) '“$_keyword”',
                        if (_series.isNotEmpty) _series,
                        if (_assetClass.isNotEmpty) _assetClass,
                        if (_classify.isNotEmpty) _classify,
                        if (_trackedOnly) '只看被跟踪',
                      ].join(' · '),
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _resetFilters,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('清空', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _loadingCard(BuildContext context) => SectionCard(
        title: '正在取指数目录',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _progressValue),
            const SizedBox(height: 8),
            Text(
              '官方全量指数表（约 3000 条）首次要拉 4 页，约 10 秒'
              '${_catalogProgress.isEmpty ? '' : '（已完成 $_catalogProgress）'}；'
              '拉完会缓存 7 天，之后离线秒开。',
              style: TextStyle(
                  fontSize: 11.5, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      );

  /// 「已完成/总页数」→ 进度条的值（解析不了就转圈）
  double? get _progressValue {
    final parts = _catalogProgress.split('/');
    if (parts.length != 2) return null;
    final d = int.tryParse(parts[0]);
    final t = int.tryParse(parts[1]);
    if (d == null || t == null || t <= 0) return null;
    return (d / t).clamp(0.0, 1.0);
  }

  Widget _errorCard(BuildContext context) => SectionCard(
        title: '指数目录没取到',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_catalogError', style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 4),
            Text(
              _catalog == null
                  ? '没有缓存可用，所以下面的列表是空的 —— 不是"指数只有这些"。'
                  : '上面这份是上次缓存的目录，可能不是最新。',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _catalogLoading ? null : () => _loadCatalog(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );

  Widget _filterCard(BuildContext context) {
    final c = _catalog;
    if (c == null) return const SizedBox.shrink();
    return SectionCard(
      title: '分类筛选',
      trailing: _sortControl(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chipRow(context, '系列', c.series, _series,
              (v) => setState(() => _series = v)),
          if (c.classifies.isNotEmpty)
            _chipRow(context, '分类', c.classifies, _classify,
                (v) => setState(() => _classify = v)),
          _chipRow(context, '资产', c.assetClasses, _assetClass,
              (v) => setState(() => _assetClass = v)),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: const Text('只看被基金跟踪的',
                  style: TextStyle(fontSize: 12)),
              selected: _trackedOnly,
              onSelected: (v) => setState(() {
                _trackedOnly = v;
                _limit = kIndexListPage;
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sortControl(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<IndexSortField>(
          tooltip: '排序字段',
          position: PopupMenuPosition.under,
          onSelected: (f) => setState(() {
            _sort = f;
            _limit = kIndexListPage;
          }),
          itemBuilder: (_) => [
            for (final f in IndexSortField.values)
              PopupMenuItem(
                value: f,
                child: Row(
                  children: [
                    if (f == _sort)
                      Icon(Icons.check,
                          size: 15, color: theme.colorScheme.primary)
                    else
                      const SizedBox(width: 15),
                    const SizedBox(width: 6),
                    Text('按${f.label}',
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
          ],
          child: Text('按${_sort.label}',
              style: TextStyle(
                  fontSize: 11.5, color: theme.colorScheme.primary)),
        ),
        IconButton(
          tooltip: _desc ? '当前：从大到小' : '当前：从小到大',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward,
              size: 16),
          onPressed: () => setState(() => _desc = !_desc),
        ),
      ],
    );
  }

  Widget _chipRow(
    BuildContext context,
    String label,
    List<String> values,
    String selected,
    void Function(String) onPick,
  ) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 34,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11.5, color: Theme.of(context).hintColor)),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final v in ['', ...values])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(v.isEmpty ? '全部' : v,
                              style: const TextStyle(fontSize: 11.5)),
                          selected: selected == v,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onSelected: (_) => onPick(v),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _resultCard(
      BuildContext context, List<IndexCatalogItem> hits, List<IndexCatalogItem> shown) {
    final theme = Theme.of(context);
    if (hits.isEmpty) {
      return SectionCard(
        title: '目录里没这条',
        child: Text(
          '中证官方目录（约 3000 条）里没有匹配的指数。'
          '国证系（980xxx）、恒生系不在这个目录里，可以用下面的联想结果查。',
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
      );
    }
    return SectionCard(
      title: '指数（${hits.length}）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final it in shown) _row(context, it),
          if (hits.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: OutlinedButton(
                  onPressed: () =>
                      setState(() => _limit += kIndexListPage),
                  child: Text(
                      '还有 ${hits.length - shown.length} 条 · 显示更多',
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IndexCatalogItem it) {
    final theme = Theme.of(context);
    final mr = it.monthlyReturn;
    final tags = [
      if (it.classify.isNotEmpty) it.classify,
      if (it.assetClass.isNotEmpty) it.assetClass,
      if (it.series.isNotEmpty) it.series.replaceAll('系列指数', ''),
      if (it.region.isNotEmpty && it.region != '境内') it.region,
      if (it.tracked) '有基金',
    ];
    return InkWell(
      onTap: () => _fetchByItem(it),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.name,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    [
                      it.code,
                      ...tags,
                      if (it.consNumber != null) '${it.consNumber}只',
                    ].join(' · '),
                    style: TextStyle(fontSize: 10.5, color: theme.hintColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(mr == null ? '--' : fmtRatioPct(mr / 100, digits: 2),
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: mr == null ? theme.hintColor : pnlColor(mr))),
                const SizedBox(height: 2),
                Text('月度',
                    style: TextStyle(fontSize: 9.5, color: theme.hintColor)),
              ],
            ),
            const Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _remoteCard(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: '联想结果',
      trailing: Text('东财联想（目录外）',
          style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_remoteSearching)
            Text('正在联想…',
                style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
          for (final c in _remote)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(c.name, style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(c.code,
                  style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _fetchByCandidate(c),
            ),
        ],
      ),
    );
  }

  Widget _recentCard(BuildContext context, List<IndexValuation> recent) =>
      SectionCard(
        title: '最近查过',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in recent)
              ActionChip(
                label: Text(v.name, style: const TextStyle(fontSize: 12)),
                onPressed: () => _fetchBySymbol(v.symbol, v.name),
              ),
          ],
        ),
      );

  Widget _footer(BuildContext context) => Text(
        '目录：中证指数官网的官方全量指数表（约 3000 条，本地缓存 7 天）—— '
        '搜索、分类、排序都在本地做，离线也能用。\n'
        '估值与股息率：蛋卷指数估值公开接口（收录范围有限）。'
        '查不到会如实说"暂无数据源"，不是"这个指数没有股息"。',
        style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
      );

  Widget _missCard(BuildContext context) => SectionCard(
        title: '这个指数暂时查不到',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「$_missName」',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              _missIsNetwork
                  ? '取数时网络出错了，过会儿再试。'
                  : '蛋卷没有收录这个指数的估值（已接入的公开源里只有它有股息率）——'
                      '不是"这个指数没有股息"，是我们暂时没有数据源。',
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
      );

  Widget _valuationCard(BuildContext context, IndexValuation v) {
    final theme = Theme.of(context);
    final y = v.yeild;
    // 蛋卷给的名字和目录里的官方名不一致时，两个都摆出来（不藏）
    final mismatch = _askedName.isNotEmpty &&
        v.name.isNotEmpty &&
        !indexNameMatches(v.name, _askedName);
    return SectionCard(
      title: v.name,
      trailing: Text(
        v.date.isEmpty ? v.symbol : '${v.symbol} · ${v.date}',
        style: TextStyle(fontSize: 11, color: theme.hintColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mismatch)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '注意：你查的是「$_askedName」，数据源返回的是「${v.name}」——对一下是不是同一个指数。',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.error),
              ),
            ),
          // 股息率放最显眼（用户就是冲它来的）；没有就如实显示 --
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('股息率',
                  style: TextStyle(fontSize: 13, color: theme.hintColor)),
              const SizedBox(width: 8),
              // 股息率是**水平值**，不能用带符号的 fmtPct（会画成 `+4.26%`，
              // 看着像收益）；分位、ROE 同理，全用不带符号的 fmtRatioPct。
              Text(y == null ? '--' : fmtRatioPct(y, digits: 2),
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              if (v.evaType.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(_evaLabel(v.evaType),
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          const Divider(height: 18),
          _kv(context, '市盈率 PE', v.pe == null ? '--' : v.pe!.toStringAsFixed(2)),
          _kv(context, '市净率 PB', v.pb == null ? '--' : v.pb!.toStringAsFixed(2)),
          _kv(context, '净资产收益率 ROE',
              v.roe == null ? '--' : fmtRatioPct(v.roe!, digits: 2)),
          _kv(context, 'PE 历史分位',
              v.pePercentile == null
                  ? '--'
                  : fmtRatioPct(v.pePercentile!, digits: 2)),
          _kv(context, 'PB 历史分位',
              v.pbPercentile == null
                  ? '--'
                  : fmtRatioPct(v.pbPercentile!, digits: 2)),
          if (v.windowStart != null) ...[
            const SizedBox(height: 6),
            Text('分位窗口：${fmtDate(v.windowStart!)} 起',
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
          ],
        ],
      ),
    );
  }

  /// 蛋卷的 `eva_type`：low / middle / high
  static String _evaLabel(String t) => switch (t.toLowerCase()) {
        'low' => '低估',
        'high' => '高估',
        'middle' => '适中',
        _ => t,
      };

  Widget _kv(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5, color: Theme.of(context).hintColor)),
            ),
            const SizedBox(width: 8),
            Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
