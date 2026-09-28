/// 交易表单的输入规则：哪个字段是用户先填的、哪个是自动算出来的
///
/// 买入是「花多少钱 → 得多少份额」，卖出是「卖多少份额 → 得多少钱」，
/// 所以主字段与派生字段随交易类型互换。这里只放纯规则，界面只管摆位置。
///
/// **场内的买入方向是反的**（2026-09-24 起）：ETF/股票是**按股数下单**
/// （填 100 股 → 算出多少钱），而场外基金是**按金额申购**（填 1000 元 → 算出份额）。
/// 这个差异只从 [AssetTraits.buyByAmount] 来，不在界面里写 `if (kind == ...)`。
library;

import '../data/asset_traits.dart';
import '../data/models.dart';

/// 表单里排在前面的主输入字段
enum PrimaryField { amount, shares, none }

/// 买入：场外基金填金额、场内填股数；卖出一律先填份额；分红只有到账金额
PrimaryField primaryFieldFor(TxnType type, AssetTraits traits) =>
    switch (type) {
      TxnType.buy => traits.buyByAmount ? PrimaryField.amount : PrimaryField.shares,
      TxnType.sell => PrimaryField.shares,
      TxnType.dividend => PrimaryField.none,
    };

/// 由金额反推份额；基金保留 2 位小数、场内按**一手**向下取整
///
/// 价格非法时返回 null，调用方据此**不覆盖**用户已填的值。
/// 场内按手（A 股与场内基金都是 100 股/份一手）：买不起一手就返回 null，
/// 让用户自己填，而不是给一个下不了单的碎股数。
double? derivedShares({
  required double amount,
  required double price,
  required AssetTraits traits,
}) {
  if (amount <= 0 || price <= 0) return null;
  if (amount.isNaN || amount.isInfinite || price.isNaN || price.isInfinite) {
    return null;
  }
  final raw = traits.unitIsFund
      ? (amount / price * 100).floorToDouble() / 100 // 场外：0.01 份
      : amount / price;
  final lot = traits.lotSize;
  final shares = traits.unitIsFund
      ? raw
      : (lot > 1 ? (raw / lot).floorToDouble() * lot : raw.floorToDouble());
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

/// **场外基金**的预测手续费（元）＝ 成交金额 × 费率（%），钱落到分。
///
/// 用户 2026-09-28 要求「区分一下场内和场外的费率设置，申购，赎回」：
/// - 场内（ETF/股票）是**券商佣金**（万分之几 + 免五）→ 走 `AppState.feeForAmount`
/// - 场外（基金）是**申购费 / 赎回费**（按基金的费率 %）→ 走这里
///
/// [ratePct] 为 null / <= 0（没设费率）→ 返回 null：界面显示 `--`，**不猜**
/// （免得把券商佣金那套硬套到场外基金上）。
double? fundTradeFee({required double? ratePct, required double amount}) {
  if (ratePct == null || ratePct <= 0) return null;
  if (amount <= 0) return null;
  if (amount.isNaN || amount.isInfinite || ratePct.isNaN || ratePct.isInfinite) {
    return null;
  }
  return double.parse((amount * ratePct / 100).toStringAsFixed(2));
}
