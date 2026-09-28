import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/index_eva.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// **指数估值**通用查询页（2026-09-28 用户口径：「能查指数估值，顺带股息率也行，
/// 做一个通用页面」）
///
/// 数据链路（详见 `data/index_eva.dart`）：指数名 →（东财联想）代码 →
/// （蛋卷）`pe / pb / **股息率** / roe / PE 分位 / PB 分位 / 窗口起点`。
///
/// 两条不能破的规矩：
/// ①**股息率是指数的**，不是某只基金分红给你的比例 —— 页面上写清楚口径，
///   免得跟基金档案页的"分红"混为一谈。
/// ②**蛋卷没收录的指数就如实说"暂无数据源"**，绝不拿别的指数顶替、
///   也不把"取不到"画成"没有股息"（覆盖率是硬上限，见数据层注释）。
class IndexValuationPage extends StatefulWidget {
  /// 搜索函数（默认走 `AppState.searchIndexes`）
  final Future<List<IndexCandidate>> Function(String query)? searchLoader;

  /// 按**蛋卷符号**取估值（默认 `AppState.loadIndexValuation`）——快捷/最近用
  final Future<IndexValuation?> Function(String symbol)? symbolLoader;

  /// 按**搜索候选**取估值（默认 `AppState.loadIndexCandidate`，内部逐个符号猜）
  final Future<IndexValuation?> Function(IndexCandidate c)? candidateLoader;

  const IndexValuationPage({
    super.key,
    this.searchLoader,
    this.symbolLoader,
    this.candidateLoader,
  });

  @override
  State<IndexValuationPage> createState() => _IndexValuationPageState();
}

class _IndexValuationPageState extends State<IndexValuationPage> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;

  List<IndexCandidate> _candidates = const [];
  bool _searching = false;
  String _lastQuery = '';

  IndexValuation? _current;
  bool _loading = false;

  /// 查了但没查到（蛋卷没收录 / 网络失败）：显示哪个词、什么原因
  String? _missName;
  bool _missIsNetwork = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  // ── 取数 ──────────────────────────────────────────────────────────────────

  Future<List<IndexCandidate>> _search(String q) {
    final loader = widget.searchLoader;
    if (loader != null) return loader(q);
    return context.read<AppState>().searchIndexes(q);
  }

  Future<IndexValuation?> _fetchSymbol(String symbol) {
    final loader = widget.symbolLoader;
    if (loader != null) return loader(symbol);
    return context.read<AppState>().loadIndexValuation(symbol);
  }

  Future<IndexValuation?> _fetchCandidate(IndexCandidate c) {
    final loader = widget.candidateLoader;
    if (loader != null) return loader(c);
    return context.read<AppState>().loadIndexCandidate(c);
  }

  void _onQueryChanged(String raw) {
    final q = raw.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _candidates = const [];
        _searching = false;
        _lastQuery = '';
      });
      return;
    }
    // 防抖：输入停下来再打联想接口（东财联想是外部请求，别每敲一下就发）
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() {
        _searching = true;
        _lastQuery = q;
      });
      final list = await _search(q);
      if (!mounted || _lastQuery != q) return;
      setState(() {
        _candidates = list;
        _searching = false;
      });
    });
  }

  Future<void> _pickSymbol(String symbol, {String? expectName}) async {
    setState(() {
      _loading = true;
      _missName = null;
      _missIsNetwork = false;
      _candidates = const [];
    });
    _query.clear();
    IndexValuation? v;
    try {
      v = await _fetchSymbol(symbol);
    } catch (_) {
      _missIsNetwork = true;
    }
    if (!mounted) return;
    setState(() {
      _current = v;
      _loading = false;
      if (v == null) _missName = expectName ?? symbol;
    });
  }

  Future<void> _pickCandidate(IndexCandidate c) async {
    setState(() {
      _loading = true;
      _missName = null;
      _missIsNetwork = false;
      _candidates = const [];
    });
    _query.clear();
    IndexValuation? v;
    var networkFail = false;
    try {
      v = await _fetchCandidate(c);
    } catch (_) {
      networkFail = true;
    }
    if (!mounted) return;
    setState(() {
      _current = v;
      _loading = false;
      if (v == null) {
        _missName = c.name;
        _missIsNetwork = networkFail;
      }
    });
  }

  // ── 界面 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // 三个 loader 都注入时（widget 测试）不读 Provider —— 测试里没有 Provider
    final injected = widget.searchLoader != null &&
        widget.symbolLoader != null &&
        widget.candidateLoader != null;
    final recent = injected
        ? const <IndexValuation>[]
        : context.watch<AppState>().recentIndexValuations;
    return Scaffold(
      appBar: AppBar(titleSpacing: 16, title: const Text('指数估值')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _searchCard(context),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_current != null)
            _valuationCard(context, _current!)
          else if (_missName != null)
            _missCard(context)
          else
            _introCard(context),
          const SizedBox(height: 12),
          _chipsCard(context, '常用指数（都有数据）', [
            for (final e in kCommonIndexSymbols)
              (label: e.name, onTap: () => _pickSymbol(e.symbol, expectName: e.name)),
          ]),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            _chipsCard(context, '最近查过', [
              for (final v in recent)
                (
                  label: v.name,
                  onTap: () => _pickSymbol(v.symbol, expectName: v.name)
                ),
            ]),
          ],
          const SizedBox(height: 12),
          Text(
            '数据来源：蛋卷指数估值（公开接口；中证指数官网也发布指数股息率，待接入）。'
            '股息率是指数的成分股分红口径，不是某只基金分红给你的比例；'
            '分位窗口起点在下面标出。\n'
            '覆盖率有限：目前只有蛋卷收录的指数能查到，其余会如实提示"暂无数据源"。',
            style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }

  Widget _searchCard(BuildContext context) => SectionCard(
        title: '查指数',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _query,
              onChanged: _onQueryChanged,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '输入指数名或代码，如「中证红利」「000922」',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('搜索中…',
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
              ),
            for (final c in _candidates)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(c.name, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(c.code,
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _pickCandidate(c),
              ),
            if (_lastQuery.isNotEmpty && !_searching && _candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('没搜到指数（东财联想只覆盖指数类；也可能名字不对）',
                    style: TextStyle(
                        fontSize: 11.5, color: Theme.of(context).hintColor)),
              ),
          ],
        ),
      );

  Widget _introCard(BuildContext context) => SectionCard(
        title: '怎么看',
        child: Text(
          '选下面「常用指数」，或搜一个指数名。\n'
          '会显示：股息率、PE、PB、ROE、PE/PB 历史分位（含窗口起点）。',
          style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
        ),
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
    return SectionCard(
      title: v.name,
      trailing: Text(
        v.date.isEmpty ? v.symbol : '${v.symbol} · ${v.date}',
        style: TextStyle(fontSize: 11, color: theme.hintColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

  Widget _chipsCard(
    BuildContext context,
    String title,
    List<({String label, VoidCallback onTap})> items,
  ) =>
      SectionCard(
        title: title,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final it in items)
              ActionChip(
                label: Text(it.label, style: const TextStyle(fontSize: 12.5)),
                onPressed: it.onTap,
              ),
          ],
        ),
      );
}
