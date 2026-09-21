import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../data/securities_repo.dart';
import '../logic/link_etf.dart';
import '../logic/rebalance_plan.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 调仓监控与再平衡（设计稿 `pic/111.jpg`）
///
/// 目标是**具体的基金 / 股票**（不再是资产大类）：每只标的一个目标占比，
/// 页面上给的是按金额算好的方案 —— 预估市值、目标市值、调仓份额、偏离，
/// 以及「需追加买入 / 需减仓卖出」多少。
///
/// 调仓总金额 = 调仓基金市值 + 追加调仓金额，目标市值 = 目标占比 × 调仓总金额，
/// 所以追加的那笔钱是按目标比例分下去的，而不是简单按现有市值摊。
///
/// 当日预估涨幅：场内标的（ETF / 股票）就是实时涨幅；场外基金没有实时行情，
/// **直接取关联 ETF 的实时涨幅**（`logic/link_etf.dart`），卡片上可以手改。
class RebalancePage extends StatefulWidget {
  const RebalancePage({super.key});

  @override
  State<RebalancePage> createState() => _RebalancePageState();
}

class _RebalancePageState extends State<RebalancePage> {
  /// 追加调仓金额
  final _extraCtrl = TextEditingController();
  double _extra = 0;

  /// 卡片上手改的「当日预估涨幅」（代码 → %）
  final Map<String, double> _pctOverride = {};
  final Map<String, TextEditingController> _pctCtrl = {};

  bool _booting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recalc());
  }

  @override
  void dispose() {
    _extraCtrl.dispose();
    for (final c in _pctCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 重新计算：先补关联 ETF，再刷行情（关联 ETF 的行情也要），最后重画
  ///
  /// 手改过的「当日预估涨幅」会一并清掉 —— 重新计算的意思就是「按最新行情重估」，
  /// 输入框里会重新填上算出来的值。
  Future<void> _recalc() async {
    if (_booting || !mounted) return;
    setState(() {
      _booting = true;
      _pctOverride.clear();
    });
    final st = context.read<AppState>();
    try {
      await st.ensureLinkEtfs();
      await st.refreshQuotes(silent: true);
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  TextEditingController _ctrlFor(PlanTarget t) {
    return _pctCtrl.putIfAbsent(
      t.code,
      () => TextEditingController(text: _pctText(t.pct)),
    );
  }

  static String _pctText(double v) {
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    if (s == '-0') s = '0';
    return s;
  }

  static String _num2(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final plan = st.rebalancePlan(extra: _extra, pctOverrides: _pctOverride);
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 13, color: theme.hintColor);

    // 手改过的输入框不动，其余跟着自动算出来的涨幅更新
    for (final line in plan.lines) {
      final t = line.target;
      if (t.kind != AssetKind.fund || _pctOverride.containsKey(t.code)) continue;
      final c = _pctCtrl[t.code];
      if (c == null) continue;
      final text = _pctText(t.pct);
      if (c.text != text) c.text = text;
    }

    // 下拉刷新 = 原来的「重新计算」（补关联 ETF + 刷行情 + 清掉手改的涨幅）；
    // 按钮去掉了，改成下拉手势，顶部标题栏那颗 ⟳ 也仍然能用
    return RefreshIndicator(
      onRefresh: _recalc,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _header(context, st, plan, theme, hint),
          _planHeader(context, plan, theme),
          if (plan.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              child: Text(
                '还没有持仓标的。先在「持仓」页记一笔买入，这里就会给出调仓方案。',
                style: TextStyle(fontSize: 13, color: theme.hintColor),
              ),
            )
          else ...[
            if (plan.unsetCount == plan.lines.length) _unsetHint(context, theme),
            for (final line in plan.lines) _card(context, st, line, theme, hint),
          ],
        ],
      ),
    );
  }

  // ---------------- 顶部汇总 ----------------

  Widget _header(
    BuildContext context,
    AppState st,
    RebalancePlan plan,
    ThemeData theme,
    TextStyle hint,
  ) {
    final thresholdPct = (plan.threshold * 100).toStringAsFixed(1)
        .replaceAll(RegExp(r'\.0$'), '');
    return Container(
      color: theme.cardColor,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('调仓总金额', style: hint),
          const SizedBox(height: 2),
          Text(
            fmtYuan(plan.total),
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('调仓基金市值', style: hint),
                    const SizedBox(height: 2),
                    Text(
                      fmtYuan(plan.estTotal),
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                // 就放个金额，不用占太宽
                width: 108,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('追加调仓金额', style: hint),
                    const SizedBox(height: 2),
                    TextField(
                      controller: _extraCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600),
                      decoration: _filledBox(),
                      onChanged: (v) => setState(() {
                        _extra = double.tryParse(v.trim()) ?? 0;
                      }),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 触发阈值直接在页面上拉：不再弹窗
          Row(
            children: [
              Text('触发阈值', style: hint),
              Expanded(
                child: Slider(
                  value: plan.threshold.clamp(0.01, 0.20),
                  min: 0.01,
                  max: 0.20,
                  divisions: 19,
                  label: '$thresholdPct%',
                  onChanged: (v) => st.setThreshold(v),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '$thresholdPct%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          if (plan.anyExceeded) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                // 淡红底用透明度叠出来，深色主题下才不会变成一块亮白
                color: const Color(0xFFE15241).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 20, color: Color(0xFFE15241)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '有基金偏离目标比例超过 $thresholdPct%，建议调仓',
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFFE15241)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _planHeader(BuildContext context, RebalancePlan plan, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text('调仓方案',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (plan.buyCount > 0)
            Text('${plan.buyCount} 买入',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFD93A3A))),
          if (plan.buyCount > 0 && plan.sellCount > 0) const SizedBox(width: 12),
          if (plan.sellCount > 0)
            Text('${plan.sellCount} 卖出',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A9C5B))),
        ],
      ),
    );
  }

  Widget _unsetHint(BuildContext context, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '还没设调仓目标：去「设置 → 调仓目标」给每只基金 / 股票填目标占比，'
              '这里才会算买卖建议。',
              style: TextStyle(fontSize: 13, color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 方案卡片 ----------------

  Widget _card(
    BuildContext context,
    AppState st,
    PlanLine line,
    ThemeData theme,
    TextStyle hint,
  ) {
    final t = line.target;
    final isFund = t.kind == AssetKind.fund;
    final color = line.hasAction && !line.isBuy
        ? const Color(0xFF1A9C5B)
        : const Color(0xFFD93A3A);

    // 目标刻度在一根条上的位置（0..1）：
    // 目标市值 ÷ Σ预估市值 = 当前占比 × (目标市值 ÷ 预估市值)
    final targetPos = (!t.hasTarget || line.est <= 0)
        ? null
        : (line.weight * (line.targetValue / line.est)).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 名称 + 代码
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(t.code, style: TextStyle(fontSize: 14, color: theme.hintColor)),
            ],
          ),
          const SizedBox(height: 10),

          // 只有真在估值（有联动涨幅）时才写「预估」；
          // 净值已是真实值、或非交易日没有估值依据 → 都按真实市值算
          _infoRow(t.estMode ? '预估' : '市值', fmtYuan(line.est), hint),
          _infoRow(
            '目标',
            t.hasTarget ? fmtYuan(line.targetValue) : '未设目标',
            hint,
            valueColor: t.hasTarget ? null : theme.hintColor,
          ),
          _infoRow(
            t.estMode ? '预估净值' : '净值',
            t.hasNav ? fmtPrice(t.nav!) : '--',
            hint,
            // 日期后缀只在**有估值依据**时才有意义（说明预估是基于哪天的净值算的）；
            // 场内看现价日期，非估值模式（非交易日）干脆不写日期。
            suffix: () {
              final d = t.navDate;
              if (d == null || d.isEmpty) return null;
              if (!isFund) return '现价 $d';
              return t.estMode ? '预估净值（$d）' : null;
            }(),
          ),
          _infoRow(
            '调仓份额',
            line.planShares == 0 ? '--' : _num2(line.planShares),
            hint,
          ),

          // 当日涨幅：真实值就是只读文本；只有估算时才给输入框手改。
          // 场外基金「既不是真实净值、又没有估值依据」（非交易日，联动 ETF 涨幅为 0）
          // 时整行不显示 —— 没有估值依据就不该摆一个预估涨幅出来。
          if (!isFund || t.navIsActual || t.estMode)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(t.estMode ? '当日预估涨幅' : '当日涨幅', style: hint),
                  const SizedBox(width: 10),
                  if (t.estMode)
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: _ctrlFor(t),
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                        ],
                        style: const TextStyle(fontSize: 14),
                        decoration: _filledBox(),
                        onChanged: (v) => setState(() {
                          // 空输入按 0 算：所见即所得，想回到自动就下拉刷新
                          _pctOverride[t.code] = double.tryParse(v.trim()) ?? 0;
                        }),
                      ),
                    )
                  else
                    Text(
                      // fmtPct 自带 %，所以下面那个单位只在输入框时才补 ——
                      // 早先无条件补，净值模式下就成了「-1.75% %」
                      fmtPct(t.pct),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: pnlColor(t.pct),
                      ),
                    ),
                  if (t.estMode) ...[
                    const SizedBox(width: 6),
                    Text('%', style: hint),
                  ],
                  if (!isFund) ...[
                    const SizedBox(width: 8),
                    Text(t.realtimePct ? '实时' : '无行情',
                        style: TextStyle(
                            fontSize: 11, color: theme.hintColor)),
                  ],
                ],
              ),
            ),

          if (isFund) _linkRow(context, st, t, theme, hint),

          const SizedBox(height: 10),
          // 需追加买入 / 需减仓卖出 + 偏离
          Row(
            children: [
              if (line.hasAction)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${line.isBuy ? '需追加买入' : '需减仓卖出'} '
                    '${fmtYuan(line.diff.abs())}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color),
                  ),
                )
              else
                Text(
                  t.hasTarget ? '已达标，不用动' : '未设目标，暂不调整',
                  style: TextStyle(fontSize: 13, color: theme.hintColor),
                ),
              const Spacer(),
              if (t.hasTarget)
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '${line.devPct > 0 ? '+' : ''}'
                          '${line.devPct.toStringAsFixed(2)}%',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: line.exceeded
                            ? color
                            : theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                    TextSpan(
                      text: '  偏离',
                      style: TextStyle(fontSize: 13, color: theme.hintColor),
                    ),
                  ]),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 进度条 = 该标的预估市值占全部预估市值的比；刻度 = 目标占比落在哪
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  height: 9,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 轨道也跟着主题，深色下不能是写死的浅灰
                      Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest),
                      FractionallySizedBox(
                        widthFactor: line.weight.clamp(0.0, 1.0),
                        child: Container(
                          color:
                              t.hasTarget ? color : const Color(0xFF9CA3AF),
                        ),
                      ),
                      // 目标刻度线：同一根条、同一分母 ——
                      // 位置 = 目标市值 ÷ Σ预估市值 = 当前占比 × (目标市值 ÷ 预估市值)
                      if (targetPos != null)
                        Align(
                          alignment: Alignment(targetPos * 2 - 1, 0),
                          child: Container(
                            width: 2,
                            height: 15,
                            decoration: BoxDecoration(
                              color: _markerColor(context),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 刻度线只有 2px 宽、又压在条子上，数字一多就不容易找到目标在哪 ——
              // 在它正下方补一个三角，指向目标占比的位置
              if (targetPos != null)
                SizedBox(
                  height: 6,
                  child: LayoutBuilder(
                    builder: (ctx, c) {
                      const w = 9.0;
                      final maxLeft =
                          (c.maxWidth - w).clamp(0.0, double.infinity);
                      final left =
                          (targetPos * c.maxWidth - w / 2).clamp(0.0, maxLeft);
                      return Stack(
                        children: [
                          Positioned(
                            left: left,
                            top: 0,
                            child: CustomPaint(
                              size: const Size(w, 5),
                              painter: _TargetTriangle(_markerColor(context)),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 关联 ETF 那一行：写出用的是哪只 ETF、它的实时涨幅，点右边可以改
  Widget _linkRow(
    BuildContext context,
    AppState st,
    PlanTarget t,
    ThemeData theme,
    TextStyle hint,
  ) {
    final linked = t.linkCode.isNotEmpty;
    return InkWell(
      onTap: () => _pickLink(st, t),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text('关联ETF', style: hint),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                linked
                    ? '${t.linkName.isEmpty ? '' : '${t.linkName} '}${t.linkCode}'
                    : '未设置',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: linked ? null : theme.hintColor,
                ),
              ),
            ),
            if (linked && t.linkPct != null) ...[
              const SizedBox(width: 6),
              Text(
                fmtPct(t.linkPct!),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: pnlColor(t.linkPct!),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.edit_outlined, size: 15, color: theme.hintColor),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, TextStyle hint,
      {Color? valueColor, String? suffix}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: hint),
          const SizedBox(width: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                suffix,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: hint.color),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 输入框底色跟主题走：写死浅灰在深色主题下会让数字看不见
  InputDecoration _filledBox() {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(6);
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder:
          OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    );
  }

  // ---------------- 交互 ----------------

  /// 选关联 ETF：搜「场内 ETF」，也可以直接清空
  Future<void> _pickLink(AppState st, PlanTarget t) async {
    final ctrl = TextEditingController(text: t.linkName);
    var rows = <SecurityRow>[];
    var searching = false;
    var ranInitial = false;
    String? error;

    Future<void> run(String kw, void Function(void Function()) setLocal) async {
      if (kw.trim().isEmpty) {
        setLocal(() => rows = []);
        return;
      }
      setLocal(() {
        searching = true;
        error = null;
      });
      final res = await st.searchAssets(kw, allowRemote: true);
      if (!mounted) return;
      setLocal(() {
        searching = false;
        error = res.error;
        rows = res.rows.where((r) => isExchangeEtfCode(r.code)).toList();
      });
    }

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // 打开就先搜一次：输入框里预填的是当前关联的那只，直接把候选摆出来
          if (!ranInitial) {
            ranInitial = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) run(ctrl.text, setLocal);
            });
          }
          return AlertDialog(
          title: const Text('关联 ETF'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '场外基金没有实时行情，当日预估涨幅直接取这只 ETF 的实时涨幅。',
                  style:
                      TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'ETF 代码 / 名称',
                    hintText: '如 159263、价值ETF',
                  ),
                  onChanged: (v) {
                    // 手输时给一小段防抖
                    Future.delayed(const Duration(milliseconds: 350), () {
                      if (ctrl.text.trim() == v.trim()) run(v, setLocal);
                    });
                  },
                ),
                const SizedBox(height: 8),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (error != null)
                  Text('联网搜索失败，可先更新基础数据',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(ctx).hintColor))
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = rows[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(r.name,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(r.subtitle,
                              style: TextStyle(
                                  fontSize: 11, color: Theme.of(ctx).hintColor)),
                          onTap: () => Navigator.pop(ctx, r.code),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (t.linkCode.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(ctx, ''),
                child: const Text('清除关联'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
          ],
        );
        },
      ),
    );

    ctrl.dispose();
    if (picked == null || t.assetId == null) return;
    await st.setAssetLink(t.assetId!, picked);
    await _recalc();
  }
}


/// 目标刻度/三角的共用颜色（跟着主题走，深色下不能是写死的灰）
Color _markerColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);

/// 目标位置下方的小三角（**尖角朝上 ▲**）—— 自绘，避免用 Icon 时被行高裁掉
class _TargetTriangle extends CustomPainter {
  _TargetTriangle(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 尖角朝上：从条子下方指着那条刻度线
    final p = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TargetTriangle old) => old.color != color;
}