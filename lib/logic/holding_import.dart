import '../data/models.dart';
import '../data/securities_repo.dart';

/// 期初持仓的一行（手工填 / 拍照 OCR 预填，两条入口共用）
class HoldingImportRow {
  String code;
  String name;
  AssetKind kind;
  String market;

  /// 从基础数据库带出的资产大类（再平衡用）
  String category;

  /// 份额
  double? shares;

  /// 成本单价
  double? costPrice;

  /// OCR 原文（仅供用户核对）
  String rawText;

  /// 是否匹配到基础数据库
  bool matched;

  /// 需要人工核对一眼的字段（'code' / 'name' / 'shares' / 'costPrice'）
  ///
  /// 拍照识别出来的行会带上它：模糊匹配到的名称、按市值反推的单价、
  /// 只有一个临时估值当成本……都算「weak」。手工录入的行这里是空的。
  final Set<String> weak = {};

  /// 模糊匹配出来的候选标的（按相似度排序，供用户挑一个）
  List<SecurityRow> candidates = const [];

  /// 用户是否已确认这一行（OCR 推断出来的行默认未确认，手工录入默认已确认）
  bool confirmed = true;

  bool get needsReview => weak.isNotEmpty;

  /// 已有持仓的份额（用于提示「该账户已有持仓」）
  double? existingShares;

  HoldingImportRow({
    this.code = '',
    this.name = '',
    this.kind = AssetKind.fund,
    this.market = '',
    this.category = '',
    this.shares,
    this.costPrice,
    this.rawText = '',
    this.matched = false,
    this.existingShares,
  });

  double? get amount =>
      (shares != null && costPrice != null) ? shares! * costPrice! : null;

  /// 整行完全没内容（只要填了任一项，就当作「有内容但可能缺字段」处理）
  bool get isBlank =>
      code.trim().isEmpty &&
      name.trim().isEmpty &&
      shares == null &&
      costPrice == null;

  String get displayName => name.isEmpty ? code : name;

  /// 返回问题描述；null 表示这一行可以导入
  String? validate() {
    if (isBlank) return '标的为空';
    if (!confirmed) return '请先确认这一行（点右上角 ✓）';
    if (code.trim().isEmpty) return '缺少代码';
    final s = shares;
    if (s == null || s <= 0) return '请填份额';
    final p = costPrice;
    if (p == null || p <= 0) return '请填成本单价';
    return null;
  }

  bool get valid => validate() == null;

  /// 生成建仓买入流水
  Txn toTxn({required int accountId, required int assetId, required DateTime date}) {
    final s = shares!;
    final p = costPrice!;
    return Txn(
      accountId: accountId,
      assetId: assetId,
      type: TxnType.buy,
      date: date,
      amount: s * p,
      shares: s,
      price: p,
      fee: 0,
      note: '期初持仓',
    );
  }

  Asset toAsset() => Asset(
        code: code.trim(),
        name: name.trim(),
        kind: kind,
        market: market,
        category: category,
      );
}

/// 整批校验：返回每一行的问题（下标与 rows 对应）
List<String?> validateRows(List<HoldingImportRow> rows) =>
    rows.map((r) => r.validate()).toList();

/// 建仓日期不能是未来
bool isValidOpenDate(DateTime date, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = DateTime(date.year, date.month, date.day);
  final t = DateTime(n.year, n.month, n.day);
  return !d.isAfter(t);
}
