import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/asset_traits.dart';
import '../data/nav_models.dart';
import '../logic/portfolio.dart';
import '../logic/period_return.dart';
import '../logic/receipt_parser.dart';
import '../data/ocr_source.dart';
import '../state/app_state.dart';
import 'asset_detail_page.dart';
import 'dca_manage_page.dart';
import 'holding_import_page.dart';
import 'widgets/common.dart';
import 'widgets/inline_marquee.dart';

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
        text: '还没有持仓\n记一笔买入，或用顶部的「添加资产」录入期初持仓',
      );
    }

    final list = state.sortedHoldings;
    final total = state.summary.marketValue;
    final showAccount = state.accountFilter == null;

    return RefreshIndicator(
      onRefresh: () => state.refreshQuotes(),
      child: ListView(
        // 断开共用的 PrimaryScrollController：IndexedStack 下 5 个页面同时活着，
        // 都挂到同一个 controller 上会互相污染滚动位置（滚动会莫名卡住/跳走）
        primary: false,
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
                // 迷你曲线与"收益是否已更新"都要看历史净值（内存里那份就够）
                navs: state.navSamples[p.asset.code],
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
              line2: '资产',
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
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
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
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
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

  /// 标的类型：场外基金的份额要固定两位小数
  /// 该标的的类型能力表（单位、价格从哪来、有没有估值……见 `data/asset_traits.dart`）
  final AssetTraits traits;

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

  /// 行情类型：`nav`（已公布净值）/ `est`（盘中估值）/ `price`（成交价）
  final String priceType;

  /// 「今年以来累计收益率」序列（%）；null = 历史不够 → **不画**曲线
  final YtdSeries? ytd;

  /// 这张卡的收益是否已按**最新公布的净值**算过（决定右上角那个状态标签）
  final bool navIsLatest;

  /// 「全部账户」时把账户名显示出来（设计稿没有，但不显示就分不清同代码的持仓）
  final String? accountName;

  /// 当日净值未更新时的预估涨跌幅（%）；null = 用真实行情或不显示
  final double? estChangePct;

  /// 对应的预估当日收益（元）
  final double? estDayPnl;

  const HoldingCardData({
    required this.name,
    required this.code,
    required this.traits,
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
    this.priceType = '',
    this.ytd,
    this.navIsLatest = true,
    this.accountName,
    this.estChangePct,
    this.estDayPnl,
  });

  factory HoldingCardData.from(
    Position p, {
    required double totalMarketValue,
    String? accountName,

    /// 该标的的历史净值（用于「今年以来收益率」迷你曲线与"收益是否已更新"判断）
    List<NavPoint>? navs,
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

    // 「收益已更新」的判断：行情的价格日期是否**不落后于**本地价格历史。
    // 场内（ETF/股票）行情是实时价 —— 只要行情带着日期就算已更新，
    // 不该因为"本地还没抓到日线"就写成「收益待更新」（旧版就是这样误报的）。
    final traits = p.asset.kind.traits;
    final infoDate = p.quote?.infoDate ?? '';
    final priceType = p.quote?.priceType ?? '';
    var lastNavDate = '';
    if (navs != null) {
      for (final n in navs) {
        if (n.date.compareTo(lastNavDate) > 0) lastNavDate = n.date;
      }
    }
    final navIsLatest = infoDate.isEmpty
        ? false
        : traits.priceIsLive
            ? (lastNavDate.isEmpty || infoDate.compareTo(lastNavDate) >= 0)
            : (lastNavDate.isEmpty
                ? priceType == 'nav'
                : infoDate.compareTo(lastNavDate) >= 0);

    return HoldingCardData(
      name: p.asset.name.isEmpty ? p.asset.code : p.asset.name,
      code: p.asset.code,
      traits: traits,
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
      infoDate: infoDate,
      priceType: priceType,
      ytd: navs == null ? null : ytdReturnSeries(navs),
      navIsLatest: navIsLatest,
      accountName: accountName,
      // 当日净值未更新时，按关联 ETF 实时行情给个预估（场内有行情则 est 为 null，不显示）
      estChangePct: p.estChangePct,
      estDayPnl: p.estDayPnl,
    );
  }

  /// 右上角状态标签（图里的「收益已更新」）—— 要如实反映状态，不硬写
  String get statusText {
    if (!hasQuote) return '无行情';
    if (estChangePct != null) return '盘中估值';
    return navIsLatest ? '收益已更新' : '收益待更新';
  }

  Color? get statusColor {
    if (!hasQuote) return null; // 用主题 hintColor
    if (estChangePct != null) return const Color(0xFFB4770A);
    return navIsLatest ? const Color(0xFF1A9C5B) : const Color(0xFFB4770A);
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
    // 内嵌浅色块：按主色轻微染色（浅色主题像图里那种淡蓝，深色主题也不刺眼）
    final panelColor = Color.alphaBlend(
        theme.colorScheme.primary.withValues(alpha: 0.08), theme.cardColor);
    final scale = MediaQuery.textScalerOf(context).scale(1.0);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1) 名称（最多两行）+ 代码 + 右侧箭头（提示可点进详情）
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                height: 1.25)),
                        const SizedBox(height: 2),
                        Text(d.code,
                            style: TextStyle(
                                fontSize: 12, color: theme.hintColor)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: theme.hintColor),
                ],
              ),
              if (d.accountName != null) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [Tag(text: d.accountName!)],
                ),
              ],

              const SizedBox(height: 10),

              // 2) 资产大字 + 右上角状态标签（收益已更新 / 盘中估值 / 待更新）
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('资产',
                      style: TextStyle(fontSize: 14, color: theme.hintColor)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        d.hasQuote ? fmtMoney(d.marketValue) : '--',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          color: d.hasQuote ? d.valueColor : theme.hintColor,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  _statusTag(context, d),
                ],
              ),

              // 3) 估值模式保留：净值未公布时按关联 ETF 给「预估涨幅 · 预估收益」
              //    宽度放不下时这段会自己横向滚动（InlineMarquee）
              if (d.estChangePct != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [Expanded(child: _estMarquee(d))]),
                ),

              const SizedBox(height: 10),

              // 4) 内嵌浅色块：左列指标 + 右侧「今年以来收益率」迷你曲线
              Container(
                decoration: BoxDecoration(
                    color: panelColor, borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                child: LayoutBuilder(
                  builder: (ctx, c) {
                    final ytd = d.ytd;
                    final metrics = Column(
                      children: [
                        // 标签按类型走：场外是「最新净值 / 净值日期」，场内是「最新价 / 行情日期」
                        _kv(context, d.traits.priceLabel, _navValue(context, d)),
                        _kv(
                            context,
                            d.traits.priceDateLabel,
                            Text(d.infoDate.isNotEmpty ? d.infoDate : '--',
                                style: const TextStyle(fontSize: 12.5))),
                        _kv(context, '当日收益', _money(context, d.dayPnl)),
                        _kv(context, '持仓收益', _money(context, d.holdingPnl)),
                        _kv(
                            context,
                            '持仓收益率',
                            _pctText(context, d.holdingPct)),
                        _kv(context, '累计收益', _money(context, d.cumulativePnl)),
                        _kv(
                            context,
                            '资产占比',
                            Text(
                                d.ratio == null ? '--' : fmtRatioPct(d.ratio!),
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600))),
                      ],
                    );
                    // 太窄就不画曲线（大字体 + 窄屏时优先保住数字）；
                    // 阈值跟着字体缩放走 —— 字体放大后文字本身就要更多横向空间。
                    if (ytd == null || c.maxWidth < 250 * scale) return metrics;
                    final w = (110.0 * scale)
                        .clamp(84.0, c.maxWidth * 0.45)
                        .toDouble();
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: metrics),
                        const SizedBox(width: 10),
                        SizedBox(width: w, child: _ytdColumn(context, ytd, d.traits)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 左列一行：标签 + 右对齐的值
  Widget _kv(BuildContext context, String label, Widget value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12.5, color: Theme.of(context).hintColor)),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                // 值可能比可用宽度还长（大字体 + 窄屏）：宁可整体缩一点，
                // 也不要 RenderFlex overflow
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: value,
                ),
              ),
            ),
          ],
        ),
      );

  /// 金额（不带百分比），按盈亏染色；null → `--`
  Widget _money(BuildContext context, double? v) => Text(
        v == null ? '--' : fmtMoneySigned(v),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: v == null ? Theme.of(context).hintColor : pnlColor(v),
        ),
      );

  /// 百分比，按盈亏染色；null → `--`
  Widget _pctText(BuildContext context, double? v) => Text(
        v == null ? '--' : fmtPct(v),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: v == null ? Theme.of(context).hintColor : pnlColor(v),
        ),
      );

  /// 「最新净值 1.0776(+0.16%)」——涨跌幅带颜色
  Widget _navValue(BuildContext context, HoldingCardData d) {
    if (d.price == null) {
      return Text('--',
          style: TextStyle(
              fontSize: 12.5, color: Theme.of(context).hintColor));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 场内按报价习惯显示 2 位小数，场外净值仍是 3~4 位
        Text(fmtPrice(d.price!, digits: d.traits.priceIsLive ? 2 : null),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        if (d.changePct != null) ...[
          const SizedBox(width: 4),
          Text('(${fmtPct(d.changePct!)})',
              style: TextStyle(fontSize: 12, color: pnlColor(d.changePct!))),
        ],
      ],
    );
  }

  /// 右侧那列：标题 + 当前值 + 迷你曲线
  Widget _ytdColumn(BuildContext context, YtdSeries ytd, AssetTraits traits) {
    final last = ytd.values.last;
    final line = pnlColor(last);
    final y = DateTime.now().year;
    // 基准在**年初或更早**（去年的最后一条就是正常情形）→ 这就是"今年以来"；
    // 只有今年才成立的标的，基准落在年内，才如实写起始日。
    // 场外基金叫「收益率」（净值口径），场内叫「涨跌幅」（价格口径）—— 算法同一个。
    final word = traits.priceIsLive ? '涨跌幅' : '收益率';
    final label = ytd.startDate.compareTo('$y-01-01') <= 0
        ? '今年以来$word'
        : '${ytd.startDate.substring(5)} 以来$word';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(label,
            textAlign: TextAlign.right,
            maxLines: 2,
            style: TextStyle(
                fontSize: 9.5,
                color: Theme.of(context).hintColor,
                height: 1.3)),
        const SizedBox(height: 3),
        Text(fmtPct(last),
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: line)),
        const SizedBox(height: 4),
        SizedBox(
          height: 44,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparklinePainter(values: ytd.values, line: line),
          ),
        ),
      ],
    );
  }

  /// 右上角状态标签
  Widget _statusTag(BuildContext context, HoldingCardData d) {
    final c = d.statusColor ?? Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(d.statusText,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600, color: c)),
    );
  }

  /// 估值模式保留：净值未公布时（且联动 ETF 有"今天"的行情）给一段跑马灯
  Widget _estMarquee(HoldingCardData d) {
    final pct = d.estChangePct!;
    final buf = StringBuffer('预估涨幅 ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%');
    if (d.estDayPnl != null) {
      final v = d.estDayPnl!;
      buf.write(' · 预估收益 ${v >= 0 ? '+' : '-'}${v.abs().toStringAsFixed(2)}');
      return InlineMarquee(
        text: buf.toString(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: pnlColor(v),
        ),
      );
    }
    return InlineMarquee(
      text: buf.toString(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: pnlColor(pct),
      ),
    );
  }

}

/// 卡片里的迷你走势线（「今年以来收益率」）—— 按项目约定自绘，不引第三方图表库
class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color line;

  const _SparklinePainter({required this.values, required this.line});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;

    var lo = values.first;
    var hi = values.first;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    var span = hi - lo;
    if (span.abs() < 1e-9) {
      // 全平（比如刚成立、还没波动）：撑开一点，免得除以 0 画成一条贴边的线
      hi = lo + 1;
      span = 1;
    }

    const pad = 2.0;
    final h = size.height - pad * 2;
    final dx = size.width / (values.length - 1);
    double yOf(double v) => pad + (1 - (v - lo) / span) * h;

    // 曲线跨 0 时画一条 0% 基准虚线，方便看"现在是赚还是亏"
    if (lo < 0 && hi > 0) {
      final y0 = yOf(0);
      final dash = Paint()
        ..color = line.withValues(alpha: 0.32)
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 4) {
        canvas.drawLine(Offset(x, y0), Offset(x + 2, y0), dash);
      }
    }

    final path = Path()..moveTo(0, yOf(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(i * dx, yOf(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.round,
    );
    // 末点一个实心小圆（跟市场估值卡片一致，标出"现在在哪"）
    canvas.drawCircle(
        Offset(size.width, yOf(values.last)), 2.0, Paint()..color = line);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.line != line ||
      old.values.length != values.length ||
      (old.values.isNotEmpty &&
          values.isNotEmpty &&
          old.values.last != values.last);
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
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
    );
  }
}
