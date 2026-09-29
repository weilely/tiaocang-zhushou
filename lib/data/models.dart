/// 数据模型定义：账户、标的、交易流水、行情快照、目标配置。
library;

/// 标的类型
enum AssetKind { fund, etf, stock, other }

extension AssetKindX on AssetKind {
  String get label => switch (this) {
        AssetKind.fund => '场外基金',
        AssetKind.etf => 'ETF/LOF',
        AssetKind.stock => '股票',
        AssetKind.other => '其他',
      };

  /// 是否在交易所实时报价（否则走基金净值接口）
  bool get isExchange => this == AssetKind.etf || this == AssetKind.stock;
}

AssetKind assetKindFromName(String? s) => AssetKind.values
    .firstWhere((e) => e.name == s, orElse: () => AssetKind.other);

/// 交易类型
enum TxnType { buy, sell, dividend }

extension TxnTypeX on TxnType {
  String get label => switch (this) {
        TxnType.buy => '买入',
        TxnType.sell => '卖出',
        TxnType.dividend => '分红',
      };

  /// 该笔交易对现金的影响（正=流入，负=流出）
  bool get isInflow => this == TxnType.sell || this == TxnType.dividend;
}

TxnType txnTypeFromName(String? s) =>
    TxnType.values.firstWhere((e) => e.name == s, orElse: () => TxnType.buy);

/// 资金账户（支付宝 / 天天基金 / 券商 …）
class Account {
  int? id;
  String name;
  String note;

  Account({this.id, required this.name, this.note = ''});

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'note': note};

  factory Account.fromMap(Map<String, Object?> m) =>
      Account(id: m['id'] as int?, name: m['name'] as String, note: (m['note'] as String?) ?? '');

  Account copyWith({int? id, String? name, String? note}) =>
      Account(id: id ?? this.id, name: name ?? this.name, note: note ?? this.note);
}

/// 投资标的
class Asset {
  int? id;
  String code;
  String name;
  AssetKind kind;

  /// 'SH' 上交所 / 'SZ' 深交所 / '' 未知（场外基金）
  String market;

  /// 用户自定义的资产大类（用于再平衡），为空时回退到标的类型
  String category;

  /// 关联 ETF 代码（场外基金估当日涨幅用；场内标的用不到，留空）
  String linkCode;

  Asset({
    this.id,
    required this.code,
    required this.name,
    required this.kind,
    this.market = '',
    this.category = '',
    this.linkCode = '',
  });

  String get displayName => name.isEmpty ? code : '$name ($code)';

  /// 实际参与再平衡统计的分类名
  String get effectiveCategory =>
      category.trim().isNotEmpty ? category.trim() : kind.label;

  Map<String, Object?> toMap() => {
        'id': id,
        'code': code,
        'name': name,
        'kind': kind.name,
        'market': market,
        'category': category,
        'link_code': linkCode,
      };

  factory Asset.fromMap(Map<String, Object?> m) => Asset(
        id: m['id'] as int?,
        code: m['code'] as String,
        name: (m['name'] as String?) ?? '',
        kind: assetKindFromName(m['kind'] as String?),
        market: (m['market'] as String?) ?? '',
        category: (m['category'] as String?) ?? '',
        linkCode: (m['link_code'] as String?) ?? '',
      );

  Asset copyWith({
    int? id,
    String? code,
    String? name,
    AssetKind? kind,
    String? market,
    String? category,
    String? linkCode,
  }) =>
      Asset(
        id: id ?? this.id,
        code: code ?? this.code,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        market: market ?? this.market,
        category: category ?? this.category,
        linkCode: linkCode ?? this.linkCode,
      );
}

/// 一笔交易流水
class Txn {
  int? id;
  int accountId;
  int assetId;
  TxnType type;
  DateTime date;

  /// 成交金额（不含手续费）。买入 = 份额×净值；卖出 = 份额×净值；分红 = 到账金额
  double amount;
  double shares;
  double price;
  double fee;
  String note;

  /// **待确认**：场外基金当天净值还没公布时，先只记金额（份额/净值留空），
  /// 等净值公布后由 `AppState.fillPendingTxns()` 自动补上份额与净值再置回 false。
  ///
  /// 用户 2026-09-28 定的做法（当时给的三选一他选了「待确认」模式）。
  /// 待确认期间这笔钱**已经进了现金账本**（买入当天就扣款），只是持仓份额还没确认
  /// —— 所以持仓里看不到它（份额为 0 视为空仓），补上后自然出现。
  bool pending;

  /// 这笔是哪个**定投计划**生成的（`dca_plans.id`；手动记的、老数据为 null）
  ///
  /// 用户 2026-09-29：「同一个标的可设置多个定投，补记功能只要期间没有」——
  /// 一旦同一标的能挂多条计划，「这一天有没有记过定投」就不能只按
  /// 账户+标的+日期 判了（会把另一条计划的期数误判成"已记过"而漏补），
  /// 必须落到**具体哪条计划**上。
  int? dcaPlanId;

  Txn({
    this.id,
    required this.accountId,
    required this.assetId,
    required this.type,
    required this.date,
    this.amount = 0,
    this.shares = 0,
    this.price = 0,
    this.fee = 0,
    this.note = '',
    this.pending = false,
    this.dcaPlanId,
  });

  /// 现金净流（负=投入资金，正=收回资金）
  ///
  /// **手续费一律并进现金流**（用户 2026-09-28 的口径：买入 3000 + 费 2.5 → 支出 302.5）：
  /// 买入 `−(金额 + 费)`、卖出 `金额 − 费`、分红 `金额 − 费`（分红也可能被渠道扣费）。
  double get netCash => switch (type) {
        TxnType.buy => -(amount + fee),
        TxnType.sell => amount - fee,
        TxnType.dividend => amount - fee,
      };

  /// 成本调整流水的备注前缀（编辑页把单位成本差值记成它）
  static const String costAdjustNote = '成本调整';

  /// 红利再投流水的备注前缀（自动分红把红利折成份额时用）
  static const String reinvestNote = '红利再投';

  /// 是不是「红利再投」：分红直接折成份额，钱没经过现金
  ///
  /// **两种备注都要认**：App 自己写的是 `红利再投 <日期>`，而对账单复刻的 CSV
  /// 里写的是 `再投`。以前只认前者，CSV 导入这类买入会照样扣现金（用户
  /// 2026-09-29 查出来的错账：948 行里 23 行、合计 1,215.12）。
  bool get isReinvest =>
      note.startsWith(reinvestNote) || note.startsWith('再投');

  /// 这笔交易**不产生现金流水**（只动成本或份额，钱没进出）
  ///
  /// - `成本调整`：编辑页改单位成本，差值是账面调整、不是真花钱
  /// - `红利再投 xxx` / `再投`：分红直接折成份额，没经过现金
  ///
  /// 判现金流缺口（`investGap`）时必须把它们排除，否则会误报
  /// 「买入没有对应的现金扣款」。
  bool get isCashless => note == costAdjustNote || isReinvest;

  Map<String, Object?> toMap() => {
        'id': id,
        'account_id': accountId,
        'asset_id': assetId,
        'type': type.name,
        'date': date.millisecondsSinceEpoch,
        'amount': amount,
        'shares': shares,
        'price': price,
        'fee': fee,
        'note': note,
        'pending': pending ? 1 : 0,
        'dca_plan_id': dcaPlanId,
      };

  factory Txn.fromMap(Map<String, Object?> m) => Txn(
        id: m['id'] as int?,
        accountId: m['account_id'] as int,
        assetId: m['asset_id'] as int,
        type: txnTypeFromName(m['type'] as String?),
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int),
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        shares: (m['shares'] as num?)?.toDouble() ?? 0,
        price: (m['price'] as num?)?.toDouble() ?? 0,
        fee: (m['fee'] as num?)?.toDouble() ?? 0,
        note: (m['note'] as String?) ?? '',
        // 老库/老备份没有这一列 → false（已确认）
        pending: ((m['pending'] as num?)?.toInt() ?? 0) == 1,
        // 老库/老备份没有这一列 → null（不是定投生成的）
        dcaPlanId: (m['dca_plan_id'] as num?)?.toInt(),
      );

  Txn copyWith({
    int? id,
    int? accountId,
    int? assetId,
    TxnType? type,
    DateTime? date,
    double? amount,
    double? shares,
    double? price,
    double? fee,
    String? note,
    bool? pending,
    int? dcaPlanId,
  }) =>
      Txn(
        id: id ?? this.id,
        accountId: accountId ?? this.accountId,
        assetId: assetId ?? this.assetId,
        type: type ?? this.type,
        date: date ?? this.date,
        amount: amount ?? this.amount,
        shares: shares ?? this.shares,
        price: price ?? this.price,
        fee: fee ?? this.fee,
        note: note ?? this.note,
        pending: pending ?? this.pending,
        dcaPlanId: dcaPlanId ?? this.dcaPlanId,
      );
}

/// 行情快照
class Quote {
  String code;
  AssetKind kind;
  String name;

  /// 用于估值的最新价格（基金为估值/净值，股票为现价）
  double price;
  double prevClose;
  double changePct;

  /// 'est' 盘中估值 / 'nav' 已公布净值 / 'price' 交易所现价
  String priceType;

  /// 数据对应的日期（基金净值日期）
  String infoDate;
  DateTime updatedAt;

  Quote({
    required this.code,
    required this.kind,
    this.name = '',
    this.price = 0,
    this.prevClose = 0,
    this.changePct = 0,
    this.priceType = 'price',
    this.infoDate = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  String get priceTypeLabel => switch (priceType) {
        'est' => '盘中估值',
        'nav' => '单位净值',
        _ => '现价',
      };

  /// 该价格所属的交易日（由 [infoDate] 解析）。无法解析时返回 null。
  DateTime? get tradeDay {
    final s = infoDate.trim();
    if (s.length < 10) return null;
    final d = DateTime.tryParse(s.substring(0, 10));
    if (d == null) return null;
    return DateTime(d.year, d.month, d.day);
  }

  /// 行情是否为今天的（false 表示还是上一个交易日的数据）
  bool isTradeDayToday([DateTime? now]) {
    final d = tradeDay;
    if (d == null) return false;
    final n = now ?? DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  Map<String, Object?> toMap() => {
        'code': code,
        'kind': kind.name,
        'name': name,
        'price': price,
        'prev_close': prevClose,
        'change_pct': changePct,
        'price_type': priceType,
        'info_date': infoDate,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Quote.fromMap(Map<String, Object?> m) => Quote(
        code: m['code'] as String,
        kind: assetKindFromName(m['kind'] as String?),
        name: (m['name'] as String?) ?? '',
        price: (m['price'] as num?)?.toDouble() ?? 0,
        prevClose: (m['prev_close'] as num?)?.toDouble() ?? 0,
        changePct: (m['change_pct'] as num?)?.toDouble() ?? 0,
        priceType: (m['price_type'] as String?) ?? 'price',
        infoDate: (m['info_date'] as String?) ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (m['updated_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
      );
}

/// 再平衡目标配置
///
/// [key] 为 `kind:fund` 形式（按标的类型）或 `asset:<code>` 形式（按个别标的）
///
/// **调仓目标按账户分开存**（v8 起）：[accountId] 是它归属的账户，
/// 同一只标的在不同账户可以有各自的目标比例，互不相干。
class TargetAlloc {
  int? id;
  int accountId;
  String key;
  String label;
  double ratio;

  TargetAlloc({
    this.id,
    this.accountId = 1,
    required this.key,
    required this.label,
    this.ratio = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'account_id': accountId,
        'key': key,
        'label': label,
        'ratio': ratio,
      };

  factory TargetAlloc.fromMap(Map<String, Object?> m) => TargetAlloc(
        id: m['id'] as int?,
        // v4 及更早的备份里没有这一列 → 归到第一个账户（老数据全是单账户）
        accountId: (m['account_id'] as num?)?.toInt() ?? 1,
        key: m['key'] as String,
        label: (m['label'] as String?) ?? '',
        ratio: (m['ratio'] as num?)?.toDouble() ?? 0,
      );

  TargetAlloc copyWith(
          {int? id, int? accountId, String? key, String? label, double? ratio}) =>
      TargetAlloc(
        id: id ?? this.id,
        accountId: accountId ?? this.accountId,
        key: key ?? this.key,
        label: label ?? this.label,
        ratio: ratio ?? this.ratio,
      );

  static String kindKey(AssetKind k) => 'kind:${k.name}';
  static String assetKey(String code) => 'asset:$code';
  static String categoryKey(String name) => 'cat:$name';
}
