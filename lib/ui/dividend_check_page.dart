import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../logic/dividend_check.dart';
import '../logic/dividend.dart';
import '../state/app_state.dart';

/// 分红核对（**只诊断，不写库**）
///
/// 用户 2026-09-22 定的顺序：**先诊断、后逐笔补记**。所以这一版只做"看名单"：
/// 把每只标的的分红/拆分事件（来自东财净值 + 累计净值）逐个对到账本上，
/// 列出 已记 / 缺记 / 对不上 / 与你无关 / 拆分提示 —— **一笔都不写**。
///
/// 为什么要这么绕：中途改过分红方式的话，账本里"当时该记什么"不能拿当前设置反推；
/// 只能先摆出来让他逐笔认，再决定补成现金还是再投（详见 logic/dividend_check.dart）。
class DividendCheckPage extends StatefulWidget {
  const DividendCheckPage({super.key});

  @override
  State<DividendCheckPage> createState() => _DividendCheckPageState();
}

class _DividendCheckPageState extends State<DividendCheckPage> {
  List<DivCheckRow>? _rows;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await context.read<AppState>().diagnoseDividends();
      if (!mounted) return;
      setState(() {
        _rows = rows;
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('分红核对', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '重新核对',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('核对失败：$err', textAlign: TextAlign.center),
        ),
      );
    }
    final rows = _rows ?? const <DivCheckRow>[];
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '没有可核对的分红或拆分事件。\n'
            '（净值里带「派现/折算」的日子才会出现在这里；\n'
            '先去关注页刷新一次历史净值试试）',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _summary(context, rows),
        for (final r in rows) _rowCard(context, r),
        const SizedBox(height: 8),
        _footnote(context),
      ],
    );
  }

  /// 汇总：几件与你有份、其中多少已记/缺记/对不上/账本负份额
  Widget _summary(BuildContext context, List<DivCheckRow> rows) {
    final held = [for (final r in rows) if (r.status != DivCheckStatus.notHeld) r];
    int n(DivCheckStatus s) => held.where((r) => r.status == s).length;
    final missing = n(DivCheckStatus.missing);
    final mismatch = n(DivCheckStatus.mismatch);
    final split = n(DivCheckStatus.split);
    final short = n(DivCheckStatus.ledgerShort);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '净值里共 ${rows.length} 次分红/拆分，与你有份 ${held.length} 次',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '已记 ${n(DivCheckStatus.cashRecorded) + n(DivCheckStatus.reinvestRecorded)}'
              '　·　缺记 $missing'
              '　·　对不上 $mismatch'
              '${short > 0 ? '　·　账本份额为负 $short' : ''}'
              '${split > 0 ? '　·　拆分提示 $split' : ''}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            if (short > 0) ...[
              const SizedBox(height: 6),
              Text(
                '「账本份额为负」= 卖出比买入多：这几乎总是前面某次红利再投没把份额记进去，'
                '先把那些补上，后面的账才算得清。',
                style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFFD93A3A),
                    height: 1.5),
              ),
            ],
            if (missing > 0 || mismatch > 0) ...[
              const SizedBox(height: 6),
              Text(
                '缺记/对不上的先别急着补 —— 这一版只诊断，'
                '下一步会逐笔让你确认补成「现金分红」还是「红利再投」。',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rowCard(BuildContext context, DivCheckRow r) {
    final theme = Theme.of(context);
    final (label, color) = _statusStyle(r.status, theme);
    final e = r.event;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${r.date}　${r.assetName}',
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: color)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(r.accountName,
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
            const SizedBox(height: 8),

            if (e.isSplit)
              _line(context, '折算系数', '每份折算 ${e.perShare.toStringAsFixed(6)} 份')
            else
              _line(context, '每份派现', '${e.perShare.toStringAsFixed(4)} 元'),
            _line(context, '当时持有', '${fmtShares(r.shares)} 份'),
            if (r.status != DivCheckStatus.notHeld) ...[
              if (e.isSplit)
                _line(context, '折算后份额', '${fmtShares(r.expectShares)} 份（×${e.perShare.toStringAsFixed(4)}）')
              else ...[
                _line(context, '应得金额', '${fmtMoney(r.expectAmount)} 元'),
                _line(context, '再投应得', '${fmtShares(r.expectShares)} 份'),
              ],
            ],
            if (r.foundNote.isNotEmpty)
              _line(context, '账本里找到',
                  '${fmtMoney(r.foundAmount)} 元'
                  '${r.foundShares > 0 ? ' / ${fmtShares(r.foundShares)} 份' : ''}'
                  '（${r.foundNote}）'),

            if (r.status == DivCheckStatus.missing ||
                r.status == DivCheckStatus.mismatch ||
                r.status == DivCheckStatus.ledgerShort) ...[
              const SizedBox(height: 6),
              Text(
                switch (r.status) {
                  DivCheckStatus.missing =>
                    '这笔没在账本里找到'
                        '${r.suggestedMode.isEmpty ? '；当时的分红方式已无从考证，补记方式要你定' : '；按当前设置建议补成${DividendMode.label(r.suggestedMode)}'}',
                  DivCheckStatus.mismatch => '账本里那笔与理论值差得多，先核对一下',
                  _ => '账本里这时是负份额：说明前面有红利再投没记份额。'
                      '先补前面的缺记（比如这只基金少的就是 '
                      '${fmtShares(r.shares.abs())} 份），这笔才核算得清。'
                      '这一版只诊断，不会替你改账。',
                },
                style: TextStyle(
                    fontSize: 11, color: theme.hintColor, height: 1.5),
              ),
            ],
            if (r.tradedOnExDate) ...[
              const SizedBox(height: 4),
              Text('⚠ 除息日当天你还有交易，份额口径（算不算当天买的）需要你确认',
                  style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFFB4770A),
                      height: 1.5)),
            ],
            if (e.consistent == false) ...[
              const SizedBox(height: 4),
              Text(
                '⚠ 净值文字与累计净值对不上（文字说每份 '
                '${e.expectDelta.toStringAsFixed(4)}，累计净值差跳了 '
                '${(e.deltaDiff ?? 0).toStringAsFixed(4)}）—— 先用同花顺的分红表核一下',
                style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFFB93A3A),
                    height: 1.5),
              ),
            ],
            if (e.consistent == null) ...[
              const SizedBox(height: 4),
              Text('（没有累计净值，这次分红未经第二来源互验）',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.5)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _footnote(BuildContext context) {
    return Text(
      '事件来自东财的净值与累计净值（每份分红 = 当天「累计净值 − 单位净值」的增量；'
      '拆分 = 折算系数）。与同花顺分红表的交叉核对见各基金的档案页。\n'
      '本次只诊断、没有写入任何数据。',
      style: TextStyle(
          fontSize: 11, color: Theme.of(context).hintColor, height: 1.6),
    );
  }

  /// 状态徽标的文案与颜色
  (String, Color) _statusStyle(DivCheckStatus s, ThemeData theme) =>
      switch (s) {
        DivCheckStatus.cashRecorded => ('已记·现金', const Color(0xFF1A9C5B)),
        DivCheckStatus.reinvestRecorded => ('已记·再投', const Color(0xFF1A9C5B)),
        DivCheckStatus.missing => ('缺记', const Color(0xFFD93A3A)),
        DivCheckStatus.mismatch => ('对不上', const Color(0xFFB93A3A)),
        DivCheckStatus.split => ('拆分提示', const Color(0xFF1F6FEB)),
        DivCheckStatus.ledgerShort => ('账本份额为负', const Color(0xFFD93A3A)),
        DivCheckStatus.notHeld => ('与你无关', theme.hintColor),
      };
}
