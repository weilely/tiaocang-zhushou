import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../logic/cash_flow.dart';
import 'common.dart';

/// 资金流「直线思维导图」
///
/// 竖直主干 + 节点挂在右侧，自上而下：
/// `期初资产 → 投入金额 / 赎回金额 → 净流入或净流出 → 账户盈亏 → 现金分红 → 期末资产`
///
/// 每个节点下面都写清**这个数是怎么来的**（充值−提现 / 买入含费 / 期末−期初−净流入），
/// 这样一眼看到的是各项统计的**总量与来源**，而不是一串流水。
class CashFlowMap extends StatelessWidget {
  final CashFlowStatement s;

  const CashFlowMap({super.key, required this.s});

  static const Color _accent = Color(0xFFC77A0A);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 期初资产
        _node(
          context,
          label: '期初资产',
          value: fmtYuan(s.beginAssets),
          formula: '持仓市值 ${fmtYuan(s.beginHolding)}'
              ' + 现金 ${fmtYuan(s.beginCash)}',
          note: s.beginMissingNav.isEmpty
              ? null
              : '含成本估值：${s.beginMissingNav.join('、')}',
          isFirst: true,
        ),

        // 投入 / 赎回（期间交易活动，不参与主链加减）
        _branchNode(
          context,
          label: '投入金额',
          value: fmtYuan(s.investAmount),
          formula: '期间买入含手续费',
        ),
        _branchNode(
          context,
          label: '赎回金额',
          value: fmtYuan(s.redeemAmount),
          formula: '期间卖出净额',
        ),

        // 净流入 / 净流出
        _node(
          context,
          label: s.netFlowLabel,
          value: fmtYuan(s.netFlow, signed: true),
          formula: '充值 ${fmtYuan(s.deposit)}'
              ' − 提现 ${fmtYuan(s.withdraw)}',
          valueColor: s.netFlow < 0
              ? const Color(0xFF1A9C5B)
              : (s.netFlow > 0 ? const Color(0xFFD93A3A) : null),
        ),

        // 现金分红：单独显示
        _node(
          context,
          label: '现金分红',
          value: fmtYuan(s.dividend),
          formula: '已计入期末资产',
          valueColor: _accent,
          accent: _accent,
        ),

        // 期末资产
        _node(
          context,
          label: '期末资产',
          value: fmtYuan(s.endAssets),
          formula: '持仓市值 ${fmtYuan(s.endHolding)}'
              ' + 现金 ${fmtYuan(s.endCash)}',
          note: s.endMissingNav.isEmpty
              ? null
              : '含成本估值：${s.endMissingNav.join('、')}',
          emphasize: true,
        ),

        // 账户盈亏放最末：它是主恒等式的**残差**，读到最后正好是结论
        _node(
          context,
          label: '账户盈亏',
          value: fmtYuan(s.pnl, signed: true),
          formula: '期末 − 期初 − ${s.netFlowLabel}',
          valueColor: pnlColor(s.pnl),
          note: s.cashAdjust.abs() > 1e-9
              ? '含现金调整 ${fmtYuan(s.cashAdjust, signed: true)}'
              : null,
          isLast: true,
        ),

        if (s.ledgerIncomplete)
          _warn(
            context,
            '现金流水不完整：本期的'
            '${s.investGap.abs() > 0.01 ? '买入 ${fmtYuan(s.investGap)} 没有对应的现金扣款' : ''}'
            '${s.investGap.abs() > 0.01 && s.redeemGap.abs() > 0.01 ? '，' : ''}'
            '${s.redeemGap.abs() > 0.01 ? '卖出 ${fmtYuan(s.redeemGap)} 没有对应的现金入账' : ''}'
            '。这笔钱没被记成支出，会被算进账户盈亏，所以它会比总览的累计收益偏大。'
            '去「现金管理」补记一笔充值或调整即可修正。',
          )
        else if (s.endCash < -1e-9)
          _warn(
            context,
            '期末现金为负：通常是买入扣款多于已记录的充值，可去现金管理页补记一笔充值',
          ),
      ],
    );
  }

  Widget _warn(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 10, left: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 15, color: Color(0xFFB4770A)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
          ],
        ),
      );

  /// 主干节点（实心圆点 + 实线）
  ///
  /// [isFirst] / [isLast] **显式传入**：以前是靠 `label == '期末资产'` 反推末节点，
  /// 一改顺序线就画错（末尾多出一截、或该连的没连上）。
  Widget _node(
    BuildContext context, {
    required String label,
    required String value,
    required String formula,
    Color? valueColor,
    String? note,
    bool emphasize = false,
    Color? accent,
    bool isFirst = false,
    bool isLast = false,
  }) {
    return _row(
      context,
      label: label,
      value: value,
      formula: formula,
      valueColor: valueColor,
      note: note,
      emphasize: emphasize,
      accent: accent,
      primary: true,
      isFirst: isFirst,
      isLast: isLast,
    );
  }

  /// 分支节点（空心圆点 + 虚线短枝）
  Widget _branchNode(
    BuildContext context, {
    required String label,
    required String value,
    required String formula,
  }) {
    return _row(
      context,
      label: label,
      value: value,
      formula: formula,
      primary: false,
    );
  }

  Widget _row(
    BuildContext context, {
    required String label,
    required String value,
    required String formula,
    required bool primary,
    Color? valueColor,
    String? note,
    bool emphasize = false,
    Color? accent,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final theme = Theme.of(context);
    final dotColor = accent ?? theme.colorScheme.primary;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 主干：竖线 + 连接短枝 + 圆点
          SizedBox(
            width: 26,
            child: CustomPaint(
              painter: _SpinePainter(
                color: theme.dividerColor,
                accent: dotColor,
                primary: primary,
                emphasize: emphasize,
                isFirst: isFirst,
                isLast: isLast,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: emphasize ? 15 : 13,
                            fontWeight:
                                emphasize ? FontWeight.w700 : FontWeight.w600,
                            color: emphasize ? null : theme.hintColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: emphasize ? 19 : 15,
                          fontWeight:
                              emphasize ? FontWeight.w700 : FontWeight.w600,
                          color: valueColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formula,
                    style: TextStyle(
                        fontSize: 10.5, color: theme.hintColor, height: 1.4),
                  ),
                  if (note != null)
                    Text(
                      note,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: accent ?? const Color(0xFFB4770A),
                        height: 1.4,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 画主干竖线、连接短枝与节点圆点
class _SpinePainter extends CustomPainter {
  final Color color;
  final Color accent;
  final bool primary;
  final bool emphasize;
  final bool isFirst;
  final bool isLast;

  _SpinePainter({
    required this.color,
    required this.accent,
    required this.primary,
    required this.emphasize,
    required this.isFirst,
    required this.isLast,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const cx = 9.0;
    final cy = size.height / 2;

    final line = Paint()
      ..color = color
      ..strokeWidth = 1.4;

    // 竖线：第一个节点之上不画，最后一个节点之下不画
    if (!isFirst) canvas.drawLine(Offset(cx, 0), Offset(cx, cy), line);
    if (!isLast) canvas.drawLine(Offset(cx, cy), Offset(cx, size.height), line);

    // 连接短枝
    final stub = Paint()
      ..color = primary ? color : color.withValues(alpha: 0.65)
      ..strokeWidth = 1.2;
    if (primary) {
      canvas.drawLine(Offset(cx, cy), Offset(cx + 8, cy), stub);
    } else {
      // 分支用虚线短枝，和主链区分开
      const dash = 2.5;
      const gap = 2.5;
      var x = cx;
      while (x < cx + 8) {
        final end = (x + dash) > cx + 8 ? cx + 8 : x + dash;
        canvas.drawLine(Offset(x, cy), Offset(end, cy), stub);
        x = end + gap;
      }
    }

    // 圆点
    final r = emphasize ? 4.5 : 3.5;
    if (primary) {
      canvas.drawCircle(Offset(cx, cy), r, Paint()..color = accent);
    } else {
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = accent
          ..strokeWidth = 1.3
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_SpinePainter old) =>
      old.color != color ||
      old.accent != accent ||
      old.primary != primary ||
      old.emphasize != emphasize ||
      old.isFirst != isFirst ||
      old.isLast != isLast;
}
