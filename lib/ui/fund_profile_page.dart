import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/fund_detail.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 基金档案页（同花顺详情接口，**点进去才拉**）
///
/// 三块数据来自三个接口：`fund/profile/detail`（档案）、
/// `fund/portfolio/holdings`（重仓股）、`fund/corporate-actions/dividends`（分红）。
///
/// 两条不能破的规则：
/// ①**按需拉取 + 缓存**（同花顺详情接口有配额），所以这里没有定时刷新，
///   只有进页面拉一次、下拉强制重拉。
/// ②**"没取到"和"没有数据"必须分开说** —— 分红接口挂了不能说成「该基金无分红」，
///   否则用户会拿着一个错结论走（见 [FundDetailBundle] 上的两个 error 字段）。
class FundProfilePage extends StatefulWidget {
  /// 6 位基金代码（不带市场前缀/后缀）
  final String code;

  /// 本地名称（同花顺的 `fund_name` 实测会被截断，所以标题用本地的）
  final String name;

  /// 标的类型：决定 thscode 用 `.OF` 还是市场后缀
  final AssetKind kind;

  const FundProfilePage({
    super.key,
    required this.code,
    required this.name,
    required this.kind,
  });

  @override
  State<FundProfilePage> createState() => _FundProfilePageState();
}

class _FundProfilePageState extends State<FundProfilePage> {
  FundDetailBundle? _bundle;
  String? _error;
  bool _loading = true;

  /// 场外基金走 `.OF`；ETF/LOF 走市场后缀
  bool get _otc => widget.kind == AssetKind.fund;

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
    try {
      final b = await context
          .read<AppState>()
          .loadFundDetail(widget.code, otc: _otc, force: force);
      if (!mounted) return;
      setState(() {
        _bundle = b;
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
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text('${widget.code} · 基金档案',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
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
        // 下拉刷新在加载态也要能用，所以不直接给 Center
        primary: false,
        children: const [
          SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在从同花顺拉取档案…',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ],
      );
    }

    final err = _error;
    if (err != null) return _errorView(context, err);

    final b = _bundle;
    if (b == null) return const SizedBox.shrink();

    return ListView(
      primary: false,
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        _profileCard(context, b),
        _managerCard(context, b.profile),
        _tradeRuleCard(context, b.profile),
        _rateCard(context, b.profile),
        _holdingCard(context, b),
        _dividendCard(context, b),
        _footer(context, b),
      ],
    );
  }

  // ---------------- 加载失败 ----------------

  Widget _errorView(BuildContext context, String message) {
    final noKey = message.contains('未配置');
    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        SectionCard(
          title: noKey ? '还没配置同花顺 API Key' : '这次没拉到数据',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                noKey
                    ? '基金档案、重仓股、分红都走同花顺的详情接口，需要你在'
                        '「设置 → 同花顺数据源」里填入自己的 API Key。\n'
                        '（App 不内置 Key，避免 APK 被反编译后泄露）'
                    : message,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _load(force: true),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 档案 ----------------

  Widget _profileCard(BuildContext context, FundDetailBundle b) {
    final p = b.profile;
    if (p.isEmpty) {
      return SectionCard(
        title: '基金档案',
        child: Text('同花顺没有返回这只基金的档案',
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
      );
    }
    return SectionCard(
      title: '基金档案',
      child: Column(
        children: [
          _kv('基金公司', p.companyName),
          _kv('成立日期', p.estabDate == null ? '--' : fmtDate(p.estabDate!)),
          _kv('最新规模', p.scaleText),
          _kv('单位净值', p.unitNav == null ? '--' : fmtPrice(p.unitNav!)),
          _kv('基金经理',
              p.managers.isNotEmpty
                  ? p.managers.map((m) => m.name).where((n) => n.isNotEmpty).join('、')
                  : p.managerName),
        ],
      ),
    );
  }

  // ---------------- 基金经理 ----------------

  Widget _managerCard(BuildContext context, FundProfile p) {
    if (p.managers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SectionCard(
      title: '基金经理（${p.managers.length}）',
      child: Column(
        children: [
          for (final m in p.managers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name.isEmpty ? '（未署名）' : m.name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        if (m.startDate != null || m.tenureDays != null)
                          Text(
                            '${m.startDate == null ? '' : '${fmtDate(m.startDate!)} 起'}'
                            '${m.tenureDays == null ? '' : ' · 任职 ${m.tenureDays} 天'}',
                            style: TextStyle(fontSize: 11, color: theme.hintColor),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _rightNum(
                    context,
                    m.tenureReturnPct == null ? '--' : fmtPct(m.tenureReturnPct!),
                    TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: m.tenureReturnPct == null
                          ? theme.hintColor
                          : pnlColor(m.tenureReturnPct!),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 交易规则 ----------------

  Widget _tradeRuleCard(BuildContext context, FundProfile p) {
    if (p.tradeRules.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: '交易规则',
      child: Column(
        children: [
          for (final r in p.tradeRules)
            _kv(r.title, r.displayTime.isEmpty ? '--' : r.displayTime),
        ],
      ),
    );
  }

  // ---------------- 费率 ----------------

  /// 费率：按 `rate_type` 分五段显示（申购 / 赎回 / 定投 / 管理费 / 托管费）
  ///
  /// 实测 `standard_rate` 是**字符串**（`"1.20%"` / `"1000元/笔"`），
  /// 而且赎回/管理费/托管费没有 `discounted_rate`、管理费托管费连 `condition` 都没有，
  /// 所以「空条目不显示、没有档位的写『全部』」，别让界面出现一行 `--`。
  Widget _rateCard(BuildContext context, FundProfile p) {
    final rates = [for (final r in p.rates) if (r.hasRate) r];
    if (rates.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    final groups = <String, List<FundRate>>{};
    for (final r in rates) {
      groups.putIfAbsent(r.type, () => []).add(r);
    }

    return SectionCard(
      title: '费率',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                _rateTypeLabel(e.key),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor),
              ),
            ),
            for (final r in e.value)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        r.condition.isEmpty ? '全部' : r.condition,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _rateText(r),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
          ],
          Text('费率为同花顺展示口径，实际以基金公司公告为准',
              style: TextStyle(fontSize: 11, color: theme.hintColor)),
        ],
      ),
    );
  }

  // ---------------- 重仓股 ----------------

  Widget _holdingCard(BuildContext context, FundDetailBundle b) {
    final theme = Theme.of(context);
    final pf = b.portfolio;
    if (pf == null) {
      return SectionCard(
        title: '重仓股',
        child: Text(b.portfolioError ?? '没有重仓股数据',
            style: TextStyle(fontSize: 13, color: theme.hintColor)),
      );
    }

    final date = pf.publishDate;
    final concentration = pf.concentrationRatio;
    return SectionCard(
      title: '重仓股${date == null ? '' : '（${fmtDate(date)}）'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: _miniStat(
                      context, '股票占净值比', _pctOrNull(pf.stockRatioPct))),
              Expanded(
                  child: _miniStat(context, '主要行业',
                      pf.mainIndustry.isEmpty ? '--' : pf.mainIndustry)),
              Expanded(
                  child: _miniStat(context, '集中度',
                      concentration == null ? '--' : _pct(concentration * 100))),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < pf.holdings.length; i++)
            _holdingRow(context, pf.holdings[i], i + 1),
          if (pf.holdings.isEmpty)
            Text('同花顺没有返回重仓股明细',
                style: TextStyle(fontSize: 13, color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _holdingRow(BuildContext context, FundStockHolding h, int fallbackRank) {
    final theme = Theme.of(context);
    final rank = h.rank ?? fallbackRank;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text('$rank',
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(h.name.isEmpty ? h.ticker : h.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5)),
                Text(
                  '${h.ticker}'
                  '${h.positionCapital == null ? '' : ' · 市值 ${fmtCompact(h.positionCapital!)}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _rightNum(
            context,
            h.holdRatio == null ? '--' : _pct(h.holdRatio!),
            const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ---------------- 分红 ----------------

  Widget _dividendCard(BuildContext context, FundDetailBundle b) {
    final theme = Theme.of(context);
    final d = b.dividends;

    if (d == null) {
      return SectionCard(
        title: '分红记录',
        child: Text(
          b.dividendsError == null ? '分红数据暂不可用' : '没取到分红数据：${b.dividendsError}',
          style: TextStyle(fontSize: 13, color: theme.hintColor),
        ),
      );
    }

    return SectionCard(
      title: d.count == null ? '分红记录' : '分红记录（${d.count} 次）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.isEmpty)
            Text(
              d.confirmedEmpty ? '这只基金没有分过红' : '同花顺没有返回分红明细',
              style: TextStyle(fontSize: 13, color: theme.hintColor),
            )
          else
            for (final it in d.items) _dividendRow(context, it),
          if (d.totalText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('累计分红：${d.totalText}',
                  style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ),
        ],
      ),
    );
  }

  Widget _dividendRow(BuildContext context, FundDividend it) {
    final theme = Theme.of(context);
    final per = it.perTenBeforeTax;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  it.exDividendDate == null
                      ? (it.publishDate == null ? '分红' : '公告 ${fmtDate(it.publishDate!)}')
                      : '除息 ${fmtDate(it.exDividendDate!)}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (per != null)
                Text('每10份 ${fmtPrice(per)} 元',
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (it.progress.isNotEmpty) it.progress,
              if (it.registrationDate != null) '权益登记 ${fmtDate(it.registrationDate!)}',
              if (it.paymentDate != null) '发放 ${fmtDate(it.paymentDate!)}',
              if (it.reinvestmentDate != null) '再投 ${fmtDate(it.reinvestmentDate!)}',
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  // ---------------- 底部说明 ----------------

  Widget _footer(BuildContext context, FundDetailBundle b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
      child: Text(
        '数据来自同花顺（按需拉取，不自动刷新）· 更新于 ${fmtDateTime(b.fetchedAt)}',
        style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
      ),
    );
  }

  // ---------------- 小组件 ----------------

  /// 一行「标签 —— 值」：值右对齐、放不下就换行，不设死宽（用户手机字体会放大）
  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: Theme.of(context).hintColor)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value.trim().isEmpty ? '--' : value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: theme.hintColor)),
        const SizedBox(height: 3),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// 右侧数字列：**统一宽度 + 右对齐**，宽度跟 textScaler 走（大字体下不会被撑爆）
  Widget _rightNum(BuildContext context, String text, TextStyle style) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return SizedBox(
      width: 76 * scale,
      child: Text(text,
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: style),
    );
  }
}

/// 百分数（值本身已经是 %）：不加正负号，避免把「占比」显示成涨跌
String _pct(double v) => '${v.toStringAsFixed(2)}%';

String _pctOrNull(double? v) => v == null ? '--' : _pct(v);

/// 费率类型的中文名（实测就这五种）
const Map<String, String> _rateTypeLabels = {
  'purchase': '申购费率',
  'redemption': '赎回费率',
  'recurring_investment': '定投费率',
  'management': '管理费',
  'custody': '托管费',
};

String _rateTypeLabel(String type) =>
    _rateTypeLabels[type] ?? (type.isEmpty ? '费率' : type);

/// 费率：优先显示折后价，并标注原价；两者相同就只写一个
String _rateText(FundRate r) {
  final d = r.discountedRate.trim();
  final s = r.standardRate.trim();
  if (d.isEmpty) return s.isEmpty ? '--' : s;
  if (s.isEmpty || s == d) return d;
  return '$d（原 $s）';
}
