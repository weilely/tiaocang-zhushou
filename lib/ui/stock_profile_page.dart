import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
// `navHistory` 是挂在 AppDatabase 上的 extension，必须 import 才在作用域里
import '../data/nav_repo.dart';
import '../data/stock_detail.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 股票资料页（同花顺 A 股接口，**点进去才拉**）
///
/// 三块数据来自三个接口（与基金档案页不是同一批）：
/// `a-share/valuations/snapshot`（估值，**带中文名**）、
/// `a-share/financials/indicators`（财务指标，按报告期）、
/// `a-share/corporate-actions/adjustment-factors`（分红送配）。
///
/// 三条不能破的规则：
/// ①**按需拉取 + 缓存**（同花顺详情接口有配额），所以没有定时刷新，
///   只有进页面拉一次、下拉强制重拉。
/// ②**"没取到"和"没有数据"必须分开说** —— 接口挂了不能写成「该股没有分红」，
///   每块各挂一个 error 字段（与基金档案页同一套规矩）。
/// ③**三块全空就降级**：同花顺 A 股侧**没有公司简介/行业这类档案接口**，
///   没覆盖的股票会三块都空 —— 这时不再假装是"资料页"，直接改成看**历史净值**
///   （本地已存的日K，见 [StockDetailBundle.hasNothing]）。
class StockProfilePage extends StatefulWidget {
  /// 6 位股票代码（不带市场前后缀）
  final String code;

  /// 本地名称（接口的中文名实测有，但本地名更稳）
  final String name;

  /// 标的类型（股票 / 指数）：只影响标题文案与 thscode 推断
  final AssetKind kind;

  /// 取数函数（默认走 `AppState.loadStockDetail`）
  ///
  /// 留注入口是为了**能单测这一页的版式与各种状态**：正常、没估值、
  /// 没分红、接口挂了、没配 Key、三块全空（降级）—— 真实环境很难凑齐，
  /// 而 widget 测试里没有 sqflite/网络，直接读 AppState 会炸。
  final Future<StockDetailBundle> Function(bool force)? loader;

  /// 历史净值（日K）取数函数（默认读本地 `db.navHistory`）
  final Future<List<NavPoint>> Function()? historyLoader;

  const StockProfilePage({
    super.key,
    required this.code,
    required this.name,
    required this.kind,
    this.loader,
    this.historyLoader,
  });

  @override
  State<StockProfilePage> createState() => _StockProfilePageState();
}

class _StockProfilePageState extends State<StockProfilePage> {
  StockDetailBundle? _bundle;
  List<NavPoint> _history = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // 依赖**在 await 之前**取好（跨 await 用 context 会被 lint 抓，也会踩空）；
    // 注入了两个 loader 时（widget 测试）根本不需要 Provider。
    final needState = widget.loader == null || widget.historyLoader == null;
    final AppState? st = needState ? context.read<AppState>() : null;
    try {
      final bundle = widget.loader != null
          ? await widget.loader!(force)
          : await st!.loadStockDetail(widget.code, force: force);
      // 历史净值失败**不影响**资料：它只是页面下半部分，读不到就当空
      List<NavPoint> history = const [];
      try {
        history = widget.historyLoader != null
            ? await widget.historyLoader!()
            : await st!.db.navHistory(widget.code);
      } catch (_) {
        history = const [];
      }
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.name.trim().isEmpty ? widget.code : widget.name;
    final isIndex = widget.kind == AssetKind.other;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text('${widget.code} · ${isIndex ? '指数资料' : '股票资料'}',
                style:
                    TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '重新拉取（同花顺有配额，不会自动刷新）',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _bundle == null) {
      return ListView(
        primary: false,
        children: const [
          SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在拉取资料（同花顺有配额，只拉这一次）',
                    style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      );
    }
    if (_error != null && _bundle == null) {
      return ListView(
        primary: false,
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: '没取到资料',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 10),
                // 取不到资料不是"这股票没有资料"：如实说明并给出口
                const Text('可能是没配同花顺 Key、配额用完或网络问题；'
                    '下面仍可看本地的历史净值。',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () => _load(force: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _historyCard(context),
        ],
      );
    }

    final b = _bundle;
    if (b == null) return const SizedBox.shrink();

    // 三块全空 → 不假装是资料页，直接看历史净值（用户口径：实在没有就显示历史净值）
    if (b.hasNothing) {
      return ListView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          SectionCard(
            title: '这只股票没有资料数据',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '同花顺 A 股侧没有公司简介/行业这类档案接口，'
                  '这只标的的估值 / 财务 / 分红也都没取到。',
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).hintColor),
                ),
                if (b.valuationError != null) ...[
                  const SizedBox(height: 6),
                  Text('估值：${b.valuationError}',
                      style: const TextStyle(fontSize: 11.5)),
                ],
                if (b.financialsError != null) ...[
                  const SizedBox(height: 2),
                  Text('财务：${b.financialsError}',
                      style: const TextStyle(fontSize: 11.5)),
                ],
                if (b.dividendsError != null) ...[
                  const SizedBox(height: 2),
                  Text('分红：${b.dividendsError}',
                      style: const TextStyle(fontSize: 11.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _historyCard(context, expanded: true),
        ],
      );
    }

    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (b.valuation != null) _valuationCard(context, b.valuation!),
        if (b.valuation == null && b.valuationError != null)
          _errorCard(context, '估值', b.valuationError!),
        const SizedBox(height: 12),
        if (b.financials != null)
          _financeCard(context, b.financials!)
        else
          _errorCard(context, '财务指标', b.financialsError ?? '没有取到'),
        const SizedBox(height: 12),
        _dividendCard(context, b),
        const SizedBox(height: 12),
        _historyCard(context),
        const SizedBox(height: 10),
        Center(
          child: Text(
            '数据来自同花顺（${_fmtTime(b.fetchedAt)} 拉取）· 同花顺有配额，本页不自动刷新',
            style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  // ── 估值卡 ────────────────────────────────────────────────────────────────

  Widget _valuationCard(BuildContext context, StockValuation v) {
    final items = <(String, double?)>[
      ('PE(TTM)', v.peTtm),
      ('PE(静)', v.peMrq),
      ('PB', v.pbMrq),
      ('PS(TTM)', v.psTtm),
      ('PCF(TTM)', v.pcfTtm),
    ];
    return SectionCard(
      title: '估值',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(v.name,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          // 两列铺开（数值都短，窄屏 + 大字体也不会挤）
          for (var i = 0; i < items.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(child: _kv(context, items[i].$1, items[i].$2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: i + 1 < items.length
                        ? _kv(context, items[i + 1].$1, items[i + 1].$2)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, double? value) => Row(
        children: [
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
          ),
          const SizedBox(width: 6),
          Text(value == null ? '--' : fmtPrice(value, digits: 2),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      );

  // ── 财务指标卡 ────────────────────────────────────────────────────────────

  Widget _financeCard(BuildContext context, StockFinancials f) {
    final blocks = <Widget>[];
    for (final g in kFinGroups) {
      final rows = <Widget>[];
      for (final r in g.rows) {
        final ind = f.indicator(r.indexId);
        if (ind == null || ind.raw.isEmpty) continue; // 该行业没这个指标 → 跳过
        rows.add(_finRow(context, r, ind));
      }
      if (rows.isEmpty) continue; // 整组都没值 → 不显示这个组
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(g.title,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary)),
      ));
      blocks.addAll(rows);
      blocks.add(const SizedBox(height: 6));
    }
    if (blocks.isEmpty) {
      return _errorCard(context, '财务指标',
          '报告期 ${f.report} 没有可比指标（该行业常见：银行没有存货/流动比率）');
    }
    return SectionCard(
      title: '财务指标',
      trailing: Text('报告期 ${f.report}',
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...blocks,
          Text(
            '百分比类按百分数表示；流动比率 / 周转率 / 倍数类为原值，不补单位。'
            '${_hasStar(f) ? '★ 为接口 id 自述含义（官方文档未收录中文名）。' : ''}',
            style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }

  bool _hasStar(StockFinancials f) {
    for (final g in kFinGroups) {
      for (final r in g.rows) {
        if (!r.unofficial) continue;
        final ind = f.indicator(r.indexId);
        if (ind != null && ind.raw.isNotEmpty) return true;
      }
    }
    return false;
  }

  Widget _finRow(BuildContext context, FinRow r, StockIndicator ind) {
    final text = _fmtIndicator(ind.num, ind.raw, r.percent);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text('${r.label}${r.unofficial ? ' ★' : ''}',
                style: const TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// 指标显示：数值能认出来就格式化（百分比类补 `%`），
  /// **认不出来就照原样显示接口字符串** —— 不猜单位、也不吞掉一个真数
  ///
  /// 小数位：**非百分比且绝对值 < 1** 的（周转率、现金比率这类）保留 4 位 ——
  /// 2 位会把总资产周转率 `0.0118` 截成 `0.01`（真机实测踩到过）。
  static String _fmtIndicator(double? num, String raw, bool percent) {
    if (num == null) return raw;
    final abs = num.abs();
    final digits = (!percent && abs > 0 && abs < 1) ? 4 : 2;
    var s = num.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return percent ? '$s%' : s;
  }

  // ── 分红送配卡 ────────────────────────────────────────────────────────────

  Widget _dividendCard(BuildContext context, StockDetailBundle b) {
    if (b.dividends.isEmpty) {
      return _errorCard(
        context,
        '分红送配',
        b.dividendsError ?? '没有查到分红送配记录',
      );
    }
    final shown = b.dividends.take(10).toList();
    return SectionCard(
      title: '分红送配',
      trailing: Text('共 ${b.dividends.length} 次',
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 82,
                    child: Text(
                      e.exDate == null ? '--' : fmtDate(e.exDate!),
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor),
                    ),
                  ),
                  Expanded(
                    child: Text(_dividendText(e),
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          if (b.dividends.length > shown.length)
            Text('只显示最近 ${shown.length} 次',
                style:
                    TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }

  static String _dividendText(StockDividendEvent e) {
    final parts = <String>[];
    final d = e.dividendPerShare;
    if (d != null && d != 0) parts.add('每股分红 ${_trim(d)} 元');
    final b = e.perShareBonus;
    if (b != null && b != 0) parts.add('每股送 ${_trim(b)} 股');
    return parts.isEmpty ? '无分红送股' : parts.join(' · ');
  }

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  // ── 历史净值（本地日K） ────────────────────────────────────────────────────

  Widget _historyCard(BuildContext context, {bool expanded = false}) {
    final pts = _history;
    final tail = pts.length > 30 ? pts.sublist(pts.length - 30) : pts;
    String? latestText;
    String? rangeText;
    if (pts.isNotEmpty) {
      final last = pts.last;
      final d = DateTime.tryParse(last.date);
      latestText = '${d == null ? last.date : fmtDate(d)}  ${fmtPrice(last.nav)}';
      if (pts.length >= 2 && pts.first.nav > 0) {
        final pct = (last.nav / pts.first.nav - 1) * 100;
        rangeText = '${pts.length} 条 · 区间 ${fmtPct(pct)}';
      }
    }
    return SectionCard(
      title: '历史净值',
      trailing: Text('本地 ${pts.length} 条',
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pts.isEmpty)
            const Text('还没有历史净值，回上一页点右上角刷新', style: TextStyle(fontSize: 12.5))
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text('最新 $latestText',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                if (rangeText != null)
                  Text(rangeText,
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 8),
            if (expanded) ...[
              for (final p in tail.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(p.date, style: const TextStyle(fontSize: 12)),
                      ),
                      Text(fmtPrice(p.nav),
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _showHistorySheet(context, tail),
                  child: const Text('查看最近 30 条'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _showHistorySheet(
      BuildContext context, List<NavPoint> tail) async {
    final name = widget.name.trim().isEmpty ? widget.code : widget.name;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('共 ${_history.length} 条历史净值，显示最近 ${tail.length} 条',
                  style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  primary: false,
                  shrinkWrap: true,
                  children: [
                    for (final p in tail.reversed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(p.date,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                            Text(fmtPrice(p.nav),
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一整块没取到时的说明卡（**"没取到"≠"没有"**）
  Widget _errorCard(BuildContext context, String title, String msg) =>
      SectionCard(
        title: title,
        child: Text(msg,
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
      );

  static String _fmtTime(DateTime t) =>
      '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
