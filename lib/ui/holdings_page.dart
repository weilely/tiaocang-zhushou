import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../logic/portfolio.dart';
import '../logic/receipt_parser.dart';
import '../data/ocr_source.dart';
import '../state/app_state.dart';
import 'asset_detail_page.dart';
import 'dca_manage_page.dart';
import 'holding_import_page.dart';
import 'widgets/common.dart';

/// 持仓页
///
/// 版式按设计稿 `pic/cc.jpg`：顶部三枚浅蓝功能按钮 → 排序行 → 每只标的一张卡片。
/// 卡片信息密度比原来高很多：市值/占比、昨日收益、持仓收益、累计收益、份额/成本，
/// 以及分隔线下的「净值（涨跌幅）」与净值日期。
///
/// 设计稿里没有「持仓合计」卡与「全部交易」入口，两者已移除；
/// 「全部交易」改到「设置 → 数据维护中心」，避免变成没有入口的死页。
class HoldingsPage extends StatelessWidget {
  const HoldingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.txns.isEmpty) {
      return const EmptyHint(
        icon: Icons.pie_chart_outline,
        text: '还没有持仓\n记一笔买入，或用顶部的「添加基金」录入期初持仓',
      );
    }

    final list = state.sortedHoldings;
    final total = state.summary.marketValue;
    final showAccount = state.accountFilter == null;

    return RefreshIndicator(
      onRefresh: () => state.refreshQuotes(),
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          _toolbar(context, state),
          HoldingSortBar(
            sortLabel: HoldingSortBar.labelOf(state.holdingsSortKey),
            ascending: !state.holdingsSortDesc,
            count: list.length,
            onPickKey: () => _pickSortKey(context, state),
            onToggleDirection: () => state.setHoldingsSort(
                state.holdingsSortKey, !state.holdingsSortDesc),
          ),
          for (final p in list)
            HoldingCard(
              data: HoldingCardData.from(
                p,
                totalMarketValue: total,
                accountName: showAccount
                    ? (state.accountsById[p.accountId]?.name ?? '未命名账户')
                    : null,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AssetDetailPage(
                    accountId: p.accountId,
                    assetId: p.asset.id!,
                  ),
                ),
              ),
            ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text('当前没有未卖出的持仓',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ),
        ],
      ),
    );
  }

  // ---------------- 三个功能入口 ----------------

  Widget _toolbar(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          _tool(context,
              icon: Icons.photo_camera_outlined,
              line1: '拍照',
              line2: '导入',
              onTap: () => _importByPhoto(context)),
          const SizedBox(width: 8),
          _tool(context,
              icon: Icons.add,
              line1: '添加',
              line2: '基金',
              onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HoldingImportPage()),
                  )),
          const SizedBox(width: 8),
          _tool(context,
              icon: Icons.event_repeat_outlined,
              line1: '定投',
              line2: '管理',
              onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DcaManagePage()),
                  )),
        ],
      ),
    );
  }

  /// 浅蓝底圆角按钮：**图标在左、两行文字在右**（照设计稿）
  Widget _tool(
    BuildContext context, {
    required IconData icon,
    required String line1,
    required String line2,
    required VoidCallback onTap,
  }) {
    final color = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: Material(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(line1,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                              color: color)),
                      Text(line2,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                              color: color)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 拍照导入 ----------------

  Future<void> _importByPhoto(BuildContext context) async {
    final state = context.read<AppState>();

    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('从图片导入持仓',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择截图'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('不用照片，手工录入'),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;

    if (source == 'manual') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const HoldingImportPage()),
      );
      return;
    }

    final ocr = OcrSource();
    var dialogShown = false;
    try {
      final path = await ocr.pickImage(fromCamera: source == 'camera');
      if (path == null || !context.mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('正在识别图片…'),
              ]),
            ),
          ),
        ),
      );
      dialogShown = true;

      final res = await ocr.recognize(path);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      dialogShown = false;

      if (!res.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${res.error}\n可以先用手工录入')),
        );
        return;
      }

      final lines = res.lines;
      if (lines.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没识别到文字，可换一张更清晰的图，或改用手工录入')),
        );
        return;
      }

      final parsed = await parseHoldingRows(
        lines,
        byCode: state.securityByCode,
        byName: state.securitiesByName,
      );

      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HoldingImportPage(
          initialRows: parsed.rows,
          sourceLabel: '图像识别（${lines.length} 行文字'
              '${parsed.headerFound ? '，已识别表头' : ''}）'
              '${parsed.reviewRows > 0 ? '，其中 ${parsed.reviewRows} 行有推断字段待核对' : ''}',
        ),
      ));
    } catch (e) {
      if (dialogShown && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('识别失败：$e\n可以先用手工录入')),
      );
    } finally {
      ocr.dispose();
    }
  }

  Future<void> _pickSortKey(BuildContext context, AppState state) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in HoldingSortBar.sortKeys.entries)
              ListTile(
                dense: true,
                title: Text(e.value),
                trailing: e.key == state.holdingsSortKey
                    ? Icon(Icons.check,
                        size: 18, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    state.setHoldingsSort(picked, state.holdingsSortDesc);
  }
}

// ==================== 排序行 ====================

/// `排序  [持仓市值 ▾]  [升序]          持有 N 只`
///
/// 纯展示组件：只收数据与回调，便于 widget 测试。
class HoldingSortBar extends StatelessWidget {
  final String sortLabel;
  final bool ascending;
  final int count;
  final VoidCallback onPickKey;
  final VoidCallback onToggleDirection;

  const HoldingSortBar({
    super.key,
    required this.sortLabel,
    required this.ascending,
    required this.count,
    required this.onPickKey,
    required this.onToggleDirection,
  });

  static const Map<String, String> sortKeys = {
    'marketValue': '持仓市值',
    'returnPct': '收益率',
    'dayPnl': '当日收益',
    'cost': '持仓成本',
  };

  static String labelOf(String key) => sortKeys[key] ?? '持仓市值';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Text('排序', style: TextStyle(fontSize: 12, color: theme.hintColor)),
          const SizedBox(width: 8),
          _pill(
            context,
            onTap: onPickKey,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(sortLabel, style: const TextStyle(fontSize: 13)),
                Icon(Icons.expand_more, size: 16, color: theme.hintColor),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _pill(
            context,
            onTap: onToggleDirection,
            child: Text(ascending ? '升序' : '降序',
                style: const TextStyle(fontSize: 13)),
          ),
          const Spacer(),
          Text('持有 $count 只',
              style: TextStyle(fontSize: 13, color: theme.hintColor)),
        ],
      ),
    );
  }

  /// 白底细边胶囊
  Widget _pill(BuildContext context,
      {required VoidCallback onTap, required Widget child}) {
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ==================== 卡片数据 ====================

/// 一张持仓卡片需要的全部数值
///
/// 把「从 Position 推导卡片数值」的逻辑抽出来，一是让卡片变成纯展示组件，
/// 二是让**口径规则可以脱离 widget 直接单测**（市值配色、昨日收益百分比、
/// 无行情与空仓时的降级）。
class HoldingCardData {
  final String name;
  final String code;

  /// 是否拿到行情；为 false 时所有金额显示 `--`
  final bool hasQuote;

  final double marketValue;

  /// 占总持仓市值的比例；总市值为 0 时为 null（显示 `--`，不冒充 0%）
  final double? ratio;

  /// 收益标签；带日期的那版（`前日收益 09-11` / `今日收益` / `当日收益`）
  ///
  /// 设计稿写的是「昨日收益」，但行情未必是昨天的：周末与开盘前打开时，
  /// 带日期能说清这个收益到底是哪天的，比写死的「昨日」准确。
  final String dayLabel;
  final double? dayPnl;
  final double? dayPct;

  final double? holdingPnl;
  final double? holdingPct;
  final double? cumulativePnl;
  final double? cumulativePct;

  final double shares;
  final double avgCost;

  final double? price;
  final double? changePct;
  final String infoDate;

  /// 「全部账户」时把账户名显示出来（设计稿没有，但不显示就分不清同代码的持仓）
  final String? accountName;

  /// 当日净值未更新时的预估涨跌幅（%）；null = 用真实行情或不显示
  final double? estChangePct;

  /// 对应的预估当日收益（元）
  final double? estDayPnl;

  const HoldingCardData({
    required this.name,
    required this.code,
    required this.hasQuote,
    required this.marketValue,
    required this.ratio,
    required this.dayLabel,
    required this.dayPnl,
    required this.dayPct,
    required this.holdingPnl,
    required this.holdingPct,
    required this.cumulativePnl,
    required this.cumulativePct,
    required this.shares,
    required this.avgCost,
    required this.price,
    required this.changePct,
    required this.infoDate,
    this.accountName,
    this.estChangePct,
    this.estDayPnl,
  });

  factory HoldingCardData.from(
    Position p, {
    required double totalMarketValue,
    String? accountName,
  }) {
    final hasQuote = p.hasQuote;

    // 占比：总市值为 0 时不显示（0.0% 会让人以为真的占 0）
    final ratio = (hasQuote && totalMarketValue.abs() > 1e-9)
        ? p.marketValue / totalMarketValue
        : null;

    // 昨日收益的百分比 = dayPnl ÷（市值 − dayPnl），与「净值(涨跌幅)」恒等：
    // dayPnl = 份额×(现价−昨收)，所以 dayPnl/(市值−dayPnl) = 涨跌幅/(100+涨跌幅) 的倒数关系
    final dayBase = p.marketValue - p.dayPnl;
    final dayPct =
        (hasQuote && dayBase.abs() > 1e-9) ? p.dayPnl / dayBase * 100 : null;

    return HoldingCardData(
      name: p.asset.name.isEmpty ? p.asset.code : p.asset.name,
      code: p.asset.code,
      hasQuote: hasQuote,
      marketValue: p.marketValue,
      ratio: ratio,
      dayLabel: p.dayPnlLabelWithDate,
      dayPnl: hasQuote ? p.dayPnl : null,
      dayPct: dayPct,
      holdingPnl: hasQuote ? p.holdingPnl : null,
      holdingPct: hasQuote ? p.floatingPctOrNull : null,
      cumulativePnl: hasQuote ? p.cumulativePnl : null,
      cumulativePct: hasQuote ? p.cumulativePct : null,
      shares: p.shares,
      avgCost: p.avgCost,
      price: hasQuote ? p.price : null,
      changePct: hasQuote ? p.quote!.changePct : null,
      infoDate: p.quote?.infoDate ?? '',
      accountName: accountName,
    );
  }

  /// 设计稿规则：**市值大字的颜色跟随「累计收益」的正负**
  ///
  /// 不是跟随市值本身 —— 稿子里累计收益为负时市值是绿的，为正时市值是红的。
  Color? get valueColor {
    final v = cumulativePnl;
    if (v == null || v == 0) return null;
    return v > 0 ? const Color(0xFFD93A3A) : const Color(0xFF1A9C5B);
  }
}

// ==================== 卡片 ====================

/// 一只标的的持仓卡片（纯展示）
class HoldingCard extends StatelessWidget {
  final HoldingCardData data;
  final VoidCallback? onTap;

  const HoldingCard({super.key, required this.data, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = data;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1) 名称 + 代码
              Row(
                children: [
                  Expanded(
                    child: Text(d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text(d.code,
                      style: TextStyle(fontSize: 14, color: theme.hintColor)),
                ],
              ),
              if (!d.hasQuote || d.accountName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      if (!d.hasQuote) const Tag(text: '无行情'),
                      if (d.accountName != null) Tag(text: d.accountName!),
                      if (d.estChangePct != null) ...[
                        const Tag(text: '预估'),
                        Tag(
                          text: '涨幅 %',
                          color: d.estChangePct! < 0
                              ? const Color(0xFF1A9C5B)
                              : const Color(0xFFD93A3A),
                        ),
                        if (d.estDayPnl != null)
                          Tag(
                            text: '预估收益 ',
                            color: d.estDayPnl! < 0
                                ? const Color(0xFF1A9C5B)
                                : const Color(0xFFD93A3A),
                          ),
                      ],
                    ],
                  ),
                ),

              const SizedBox(height: 8),

              // 2) 市值 + 占比
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('市值',
                      style: TextStyle(fontSize: 15, color: theme.hintColor)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        d.hasQuote ? fmtMoney(d.marketValue) : '--',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          color: d.hasQuote ? d.valueColor : theme.hintColor,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text('占比',
                      style: TextStyle(fontSize: 15, color: theme.hintColor)),
                  const SizedBox(width: 6),
                  Text(d.ratio == null ? '--' : fmtRatioPct(d.ratio!),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ],
              ),

              const SizedBox(height: 10),

              _pnlRow(context, d.dayLabel, d.dayPnl, d.dayPct),
              _pnlRow(context, '持仓收益', d.holdingPnl, d.holdingPct),
              _pnlRow(context, '累计收益', d.cumulativePnl, d.cumulativePct),

              const SizedBox(height: 8),

              // 6) 份额 + 成本
              Row(
                children: [
                  Text('份额',
                      style: TextStyle(fontSize: 14, color: theme.hintColor)),
                  const SizedBox(width: 6),
                  Text(fmtShares(d.shares),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('成本',
                      style: TextStyle(fontSize: 14, color: theme.hintColor)),
                  const SizedBox(width: 6),
                  Text(fmtPrice(d.avgCost),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),

              const Divider(height: 18, thickness: 0.5),

              // 7) 净值（涨跌幅） + 净值日期
              Row(
                children: [
                  Text(d.price == null ? '--' : fmtPrice(d.price!),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  if (d.changePct != null) ...[
                    const SizedBox(width: 6),
                    Text('(${fmtPct(d.changePct!)})',
                        style: TextStyle(
                            fontSize: 15, color: pnlColor(d.changePct!))),
                  ],
                  const Spacer(),
                  Text(d.infoDate.isNotEmpty ? d.infoDate : '--',
                      style: TextStyle(fontSize: 14, color: theme.hintColor)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一行收益：左「标签 + 金额」，右「百分比」
  Widget _pnlRow(
      BuildContext context, String label, double? amount, double? pct) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 14, color: theme.hintColor)),
          const SizedBox(width: 8),
          Text(
            amount == null ? '--' : fmtMoneySigned(amount),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: amount == null ? theme.hintColor : pnlColor(amount),
            ),
          ),
          const Spacer(),
          Text(
            pct == null ? '--' : fmtPct(pct),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: pct == null ? theme.hintColor : pnlColor(pct),
            ),
          ),
        ],
      ),
    );
  }
}

/// 小标签（无行情、账户名、预估）
class Tag extends StatelessWidget {
  final String text;

  /// 标签文字颜色；不传则用主题提示色
  final Color? color;

  const Tag({super.key, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final c = color ?? hint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
    );
  }
}
