/// 基金分红：从「分红送配」原文里解析每份派现金额，并按分红方式决定产生什么交易
///
/// 净值的 `dividend` 字段来自行情源原文，实测东财 `unitMoney` 只有两种形态：
/// - `分红：每份派现金0.03元`     ← 现金分红
/// - `拆分：每份基金份额折算3.993900918份` ← 份额折算，**不是**分红
///
/// 所以判定依据是必须含「派现」，再抠出金额；`每10份派现金X元` 这种要除以 10。
library;

/// 从分红送配原文解析**每份**派现金额（元/份）；不是现金分红返回 null
double? perShareDividend(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  // 拆分 / 折算 一律不算分红
  if (!t.contains('派现')) return null;
  // 「每(10)份……派现……0.30」——份数缺省为 1
  final m = RegExp(r'每\s*(\d*)\s*份[^0-9]{0,8}?([0-9]+(?:\.[0-9]+)?)')
      .firstMatch(t);
  if (m == null) return null;
  final per = int.tryParse(m.group(1)?.trim() ?? '') ?? 1;
  final amount = double.tryParse(m.group(2) ?? '');
  if (amount == null || amount <= 0) return null;
  final n = per <= 0 ? 1 : per;
  return amount / n;
}

/// 分红方式
class DividendMode {
  /// 不自动生成（默认）
  static const String none = '';

  /// 现金分红 → 记一笔分红入账（联动现金流入）
  static const String cash = 'cash';

  /// 红利再投 → 记一笔买入（份额增加，不动现金）
  static const String reinvest = 'reinvest';

  static String label(String mode) => switch (mode) {
        cash => '现金分红',
        reinvest => '红利再投',
        _ => '不自动',
      };

  static bool isValid(String mode) => mode == cash || mode == reinvest;
}
