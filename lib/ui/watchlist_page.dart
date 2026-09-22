import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
import '../data/nav_repo.dart';
import '../data/securities_repo.dart';
import '../data/securities_source.dart';
import '../logic/holding_import.dart';
import '../logic/period_return.dart';
import '../state/app_state.dart';
import 'fund_profile_page.dart';
import 'holding_import_page.dart';
import 'widgets/common.dart';
import 'widgets/macro_card.dart';
import 'widgets/return_table.dart';
import 'widgets/segmented_pills.dart';

class WatchlistPage extends StatefulWidget {
  const WatchlistPage({super.key});

  @override
  State<WatchlistPage> createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<SecurityRow> _results = const [];
  bool _searching = false;
  bool _sortMode = false;

  /// 列表分类：null=全部，否则是 `AssetKind`。
  ///
  /// 注意 `WatchItem.kind` 是 **AssetKind 枚举**、不是字符串 —— 早先拿
  /// `== 'fund'` 去比永远为假（标签全显示 0），而这类错误只是 info 级 lint
  /// `unrelated_type_equality_checks`，很容易被"只看 error/warning"放过去。
  AssetKind? _kind;

  /// 三个分类标签的顺序与中文名（用户口径：基金 / 股票 / ETF）
  static const List<AssetKind> kindTabs = [
    AssetKind.fund,
    AssetKind.stock,
    AssetKind.etf,
  ];

  static String kindLabel(AssetKind kind) => switch (kind) {
        AssetKind.fund => '基金',
        AssetKind.stock => '股票',
        AssetKind.etf => 'ETF',
        AssetKind.other => '其他',
      };

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), _runSearch);
  }

  Future<void> _runSearch() async {
    final kw = _search.text.trim();
    if (kw.isEmpty) return;
    setState(() => _searching = true);
    final st = context.read<AppState>();
    final res = await st.searchAssets(kw, limit: 20);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = res.rows;
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();

    // 分类标签：全部 + 基金/股票/ETF **三个固定分类**（各自带数量）。
    // 不按"有没有这类标的"来决定显不显示 —— 用户要的就是这三个标签，
    // 藏起来等于没做；数量为 0 反而一眼看得出这类还没加。
    final allRows = st.watchRows;
    final kind = _kind;
    final rows = kind == null
        ? allRows
        : [for (final r in allRows) if (r.item.kind == kind) r];

    return Column(
      children: [
        _searchBar(context, st),
        if (_search.text.trim().isNotEmpty)
          Expanded(child: _searchResults(context, st))
        else if (_sortMode)
          Expanded(child: _reorderList(context, st))
        else ...[
          _statsBar(context, st, rows),
          // 市场估值（股债利差）：一天一个点，本地累积历史
          const MacroCard(),
          // 分类标签 + 标的列表**合成一张卡**（用户要求）：
          // 标签就是这张表的"表头"，原先飘在表格外面，看着是两块东西
          Expanded(
            child: Card(
              margin: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              elevation: 0,
              color: Theme.of(context).cardColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (allRows.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      // 用户要求：标签**横向平均分布**（原来 expand:false 是按文字
                      // 宽度挤在左边、右侧留一大片空白）。用 expand:true 让每个标签
                      // 等宽铺满，所以外面的 Align 也不需要了。
                      child: SegmentedPills<AssetKind?>(
                        expand: true,
                        selected: kind,
                        onChanged: (v) => setState(() => _kind = v),
                        items: [
                          (value: null, label: '全部 ${allRows.length}'),
                          for (final k in kindTabs)
                            (
                              value: k,
                              label:
                                  '${kindLabel(k)} ${allRows.where((r) => r.item.kind == k).length}'
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ReturnTable(
                      rows: rows,
                      emptyText: kind == null
                          ? '还没有关注的标的'
                          : '这个分类下还没有标的',
                      onTap: _showNavHistory,
                      onMenu: (r) => _itemMenu(st, r),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------- 搜索与工具栏 ----------------

  Widget _searchBar(BuildContext context, AppState st) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索基金 / 股票，添加到关注',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : (_search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                                  _search.clear();
                                  _results = const [];
                                }),
                          )),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: _sortMode ? '完成排序' : '拖动排序 / 置顶',
            onPressed: () => setState(() => _sortMode = !_sortMode),
            icon: Icon(_sortMode ? Icons.check : Icons.swap_vert),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: '刷新历史净值',
            onPressed: st.navUpdating ? null : () => _refreshNav(st),
            icon: st.navUpdating
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _statsBar(BuildContext context, AppState st, List<WatchRow> rows) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Row(
        children: [
          // 分类筛选后显示的是**当前看到的那一批**有几只，避免"共 9 只却只列 3 行"的疑惑
          Text('共 ${rows.length} 只',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          const SizedBox(width: 10),
          Text('净值 ${st.navRowCount} 条',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          const Spacer(),
          if (st.navUpdating)
            Text('更新中 ${st.navProgress}',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.primary))
          else
            Text(
              st.navUpdatedAt == null
                  ? '净值未更新'
                  : '更新于 ${fmtDateTime(st.navUpdatedAt!)}',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
        ],
      ),
    );
  }

  // ---------------- 搜索结果 ----------------

  Widget _searchResults(BuildContext context, AppState st) {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return EmptyHint(
        icon: Icons.search_off,
        text: '没找到匹配的标的\n可先去「设置 → 数据维护中心」更新基础数据',
      );
    }
    // 已经在关注列表里的，图标要变成「减号」——早先只看有没有搜到，
    // 已关注的也照样给个加号，点下去还会重复关注 + 白刷一次行情
    final watched = {for (final w in st.watchlist) w.code: w};
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = _results[i];
        final already = watched[r.code];
        return ListTile(
          dense: true,
          title: Text(r.name.isEmpty ? r.code : r.name,
              style: const TextStyle(fontSize: 14)),
          subtitle: Text(r.subtitle,
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          trailing: IconButton(
            tooltip: already == null ? '加入关注' : '取消关注',
            icon: Icon(already == null
                ? Icons.add_circle_outline
                : Icons.remove_circle_outline),
            onPressed: () async {
              // 先取好 messenger：await 之后就不能再用 context 了
              // （analyzer 的 use_build_context_synchronously 会拦，
              //   而且真的可能在不该用的时候用）
              final messenger = ScaffoldMessenger.of(context);
              if (already == null) {
                await st.addToWatch(Asset(
                  code: r.code,
                  name: r.name,
                  kind: r.assetKind,
                  market: r.market,
                  category: assetCategoryFor(r),
                ));
                if (!mounted) return;
                // 不清空搜索：列表留着，图标自己会翻成「−」，方便连着加好几只
                setState(() {});
                messenger.showSnackBar(SnackBar(
                    content: Text('已加入关注：${r.name}'),
                    duration: const Duration(seconds: 2)));
                return;
              }
              // 取消关注要先确认 —— 确认了才做删除与后续刷新
              final yes = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('取消关注？'),
                  content: Text('「${r.name.isEmpty ? r.code : r.name}」将从关注列表移除。\n'
                      '已记录的历史净值会保留。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('再想想')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('取消关注')),
                  ],
                ),
              );
              if (yes != true || !mounted) return;
              await st.removeFromWatch(already.id!);
              if (!mounted) return;
              setState(() {});
              messenger.showSnackBar(SnackBar(
                  content: Text('已取消关注：${r.name}'),
                  duration: const Duration(seconds: 2)));
            },
          ),
        );
      },
    );
  }

  // ---------------- 拖动排序模式 ----------------

  Widget _reorderList(BuildContext context, AppState st) {
    final items = st.watchlist;
    if (items.isEmpty) {
      return const EmptyHint(icon: Icons.star_border, text: '还没有关注的标的\n在上面搜索框里添加');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          child: Text('长按右侧手柄拖动排序；置顶的条目恒在最前',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: items.length,
            onReorderItem: (oldIndex, newIndex) {
              final list = List<WatchItem>.from(items);
              final moved = list.removeAt(oldIndex);
              list.insert(newIndex, moved);
              st.reorderWatch(list);
            },
            itemBuilder: (_, i) {
              final w = items[i];
              return ListTile(
                key: ValueKey('watch-${w.id}'),
                dense: true,
                leading: IconButton(
                  tooltip: w.pinned ? '取消置顶' : '置顶',
                  icon: Icon(
                    w.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                    color: w.pinned ? Theme.of(context).colorScheme.primary : null,
                  ),
                  onPressed: () => st.toggleWatchPin(w),
                ),
                title: Text(w.code, style: const TextStyle(fontSize: 14)),
                subtitle: Text(w.name.isEmpty ? '（未命名）' : w.name,
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
                trailing: ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_handle),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------- 交互 ----------------

  Future<void> _refreshNav(AppState st) async {
    final n = await st.updateNavHistory(manual: true);
    if (!mounted) return;
    if (n == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可更新的标的，或接口暂时不可用')),
      );
    }
  }

  Future<void> _itemMenu(AppState st, WatchRow r) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: Icon(r.item.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(r.item.pinned ? '取消置顶' : '置顶'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline_outlined),
              title: const Text('查看历史净值'),
              onTap: () => Navigator.pop(ctx, 'nav'),
            ),
            // 基金档案走同花顺的基金详情接口：股票/黄金没有这一项
            if (r.item.kind == AssetKind.fund || r.item.kind == AssetKind.etf)
              ListTile(
                dense: true,
                leading: const Icon(Icons.description_outlined),
                title: const Text('基金档案（重仓股 / 分红）'),
                onTap: () => Navigator.pop(ctx, 'profile'),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.savings_outlined),
              title: const Text('移到持仓（录入期初持仓）'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除关注'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'pin':
        await st.toggleWatchPin(r.item);
      case 'nav':
        await _showNavHistory(r);
      case 'profile':
        await _showFundProfile(r);
      case 'move':
        final row = HoldingImportRow(
          code: r.item.code,
          name: r.item.name,
          kind: r.item.kind,
          market: r.item.market,
          costPrice: r.nav,
          matched: true,
        );
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => HoldingImportPage(
            initialRows: [row],
            sourceLabel: '来自关注：${r.item.displayName}',
          ),
        ));
      case 'delete':
        await st.removeFromWatch(r.item.id!);
    }
  }

  /// 打开基金档案页（同花顺详情接口：档案 / 重仓股 / 分红）
  Future<void> _showFundProfile(WatchRow r) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FundProfilePage(
        code: r.item.code,
        name: r.item.displayName,
        kind: r.item.kind,
      ),
    ));
  }

  Future<void> _showNavHistory(WatchRow r) async {
    final st = context.read<AppState>();
    final pts = await st.db.navHistory(r.item.code);
    if (!mounted) return;
    final tail = pts.length > 30 ? pts.sublist(pts.length - 30) : pts;
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
              Text(r.item.displayName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('共 ${pts.length} 条历史净值，显示最近 ${tail.length} 条',
                  style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor)),
              const SizedBox(height: 8),
              if (tail.isEmpty)
                const Text('还没有净值数据，点右上角刷新')
              else
                Flexible(
                  child: ListView(
        // 断开共用的 PrimaryScrollController：IndexedStack 下 5 个页面同时活着，
        // 都挂到同一个 controller 上会互相污染滚动位置（滚动会莫名卡住/跳走）
        primary: false,
                    shrinkWrap: true,
                    children: [
                      for (final p in tail.reversed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                  width: 92,
                                  child: Text(p.date,
                                      style: const TextStyle(fontSize: 12))),
                              SizedBox(
                                width: 76,
                                child: Text(fmtPrice(p.nav),
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              SizedBox(
                                width: 76,
                                child: Text(
                                  formatReturnPct(p.changePct),
                                  style: TextStyle(
                                      fontSize: 12, color: pnlColor(p.changePct)),
                                ),
                              ),
                              if (p.hasDividend)
                                const Text('分红',
                                    style: TextStyle(
                                        fontSize: 11, color: Color(0xFFB4770A))),
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
}
