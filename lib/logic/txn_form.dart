/// 交易表单的输入规则：哪个字段是用户先填的、哪个是自动算出来的
///
/// 买入是「花多少钱 → 得多少份额」，卖出是「卖多少份额 → 得多少钱」，
/// 所以主字段与派生字段随交易类型互换。这里只放纯规则，界面只管摆位置。
library;

import '../data/dca_models.dart';
import '../data/models.dart';

/// 表单里排在前面的主输入字段
enum PrimaryField { amount, shares, none }

/// 买入主金额、卖出主份额、分红只有到账金额
PrimaryField primaryFieldFor(TxnType type) => switch (type) {
      TxnType.buy => PrimaryField.amount,
      TxnType.sell => PrimaryField.shares,
      TxnType.dividend => PrimaryField.none,
    };

/// 由金额反推份额；基金/ETF 保留 2 位小数、股票取整（与定投同一口径）
///
/// 价格非法时返回 null，调用方据此**不覆盖**用户已填的值。
double? derivedShares({
  required double amount,
  required double price,
  required AssetKind kind,
}) {
  if (amount <= 0 || price <= 0) return null;
  if (amount.isNaN || amount.isInfinite || price.isNaN || price.isInfinite) {
    return null;
  }
  final shares = roundDcaShares(amount / price, kind);
  return shares > 0 ? shares : null;
}

/// 由份额算金额
double? derivedAmount({required double shares, required double price}) {
  if (shares <= 0 || price <= 0) return null;
  if (shares.isNaN || shares.isInfinite || price.isNaN || price.isInfinite) {
    return null;
  }
  return shares * price;
}
