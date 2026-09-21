import 'dart:convert';

import 'models.dart';

/// 关注（自选）列表里的一项
class WatchItem {
  int? id;
  String code;
  AssetKind kind;
  String name;
  String market;
  int sortOrder;
  bool pinned;
  DateTime createdAt;

  WatchItem({
    this.id,
    required this.code,
    required this.kind,
    this.name = '',
    this.market = '',
    this.sortOrder = 0,
    this.pinned = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get displayName => name.isEmpty ? code : name;

  Map<String, Object?> toMap() => {
        'id': id,
        'code': code,
        'kind': kind.name,
        'name': name,
        'market': market,
        'sort_order': sortOrder,
        'pinned': pinned ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory WatchItem.fromMap(Map<String, Object?> m) => WatchItem(
        id: m['id'] as int?,
        code: (m['code'] as String?) ?? '',
        kind: assetKindFromName(m['kind'] as String?),
        name: (m['name'] as String?) ?? '',
        market: (m['market'] as String?) ?? '',
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
        pinned: ((m['pinned'] as num?)?.toInt() ?? 0) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['created_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
      );

  WatchItem copyWith({int? id, String? name, int? sortOrder, bool? pinned}) =>
      WatchItem(
        id: id ?? this.id,
        code: code,
        kind: kind,
        name: name ?? this.name,
        market: market,
        sortOrder: sortOrder ?? this.sortOrder,
        pinned: pinned ?? this.pinned,
        createdAt: createdAt,
      );
}

/// 一条历史净值（股票/ETF 存的是收盘价）
class NavPoint {
  final String code;

  /// yyyy-MM-dd
  final String date;
  final double nav;

  /// 累计净值；股票/ETF 与 [nav] 相同
  final double accNav;
  final double changePct;

  /// 分红送配原文，非空即当日有分红
  final String dividend;

  const NavPoint({
    required this.code,
    required this.date,
    required this.nav,
    this.accNav = 0,
    this.changePct = 0,
    this.dividend = '',
  });

  bool get hasDividend => dividend.trim().isNotEmpty;

  /// 计算区间收益时优先用累计净值（分红再投资口径）
  double get value => accNav > 0 ? accNav : nav;

  Map<String, Object?> toMap() => {
        'code': code,
        'date': date,
        'nav': nav,
        'acc_nav': accNav,
        'change_pct': changePct,
        'dividend': dividend,
      };

  factory NavPoint.fromMap(Map<String, Object?> m) => NavPoint(
        code: (m['code'] as String?) ?? '',
        date: (m['date'] as String?) ?? '',
        nav: (m['nav'] as num?)?.toDouble() ?? 0,
        accNav: (m['acc_nav'] as num?)?.toDouble() ?? 0,
        changePct: (m['change_pct'] as num?)?.toDouble() ?? 0,
        dividend: (m['dividend'] as String?) ?? '',
      );
}

/// 现金流水类型
class CashType {
  static const deposit = 'deposit';
  static const withdraw = 'withdraw';
  static const adjust = 'adjust';

  /// 收益（货币基金/国债逆回购的利息），记为正数入账
  static const income = 'income';

  /// 买入扣款（由交易联动生成）
  static const invest = 'invest';

  /// 卖出入账（由交易联动生成）
  static const redeem = 'redeem';

  /// 分红入账（由交易联动生成）
  static const dividend = 'dividend';

  /// 手动可记的类型（其余由交易联动生成，不放进手动入口）
  static const manualTypes = [deposit, withdraw, adjust, income];

  static String label(String t) => switch (t) {
        deposit => '充值',
        withdraw => '提现',
        adjust => '调整',
        income => '收益',
        // 简洁优先：不写「买入扣款 / 卖出入账 / 分红入账」——
        // 金额的正负号与红绿已经把「钱进还是钱出」说清楚了
        invest => '买入',
        redeem => '卖出',
        dividend => '分红',
        _ => t,
      };
}

/// 一笔现金流水（余额 = 所有 amount 之和）
class CashTxn {
  int? id;
  int accountId;
  String type;

  /// 带符号：充值为正、提现为负、调整可正可负、收益为正
  double amount;
  DateTime date;
  String note;
  DateTime createdAt;

  /// 由哪笔交易联动生成（买/卖/分红）；手动记录的为 null
  int? srcTxnId;

  CashTxn({
    this.id,
    required this.accountId,
    required this.type,
    required this.amount,
    required this.date,
    this.note = '',
    DateTime? createdAt,
    this.srcTxnId,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isIncome => type == CashType.income;

  String get typeLabel => CashType.label(type);

  Map<String, Object?> toMap() => {
        'id': id,
        'account_id': accountId,
        'type': type,
        'amount': amount,
        'date': date.millisecondsSinceEpoch,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
        'src_txn_id': srcTxnId,
      };

  factory CashTxn.fromMap(Map<String, Object?> m) => CashTxn(
        id: m['id'] as int?,
        accountId: (m['account_id'] as num).toInt(),
        type: (m['type'] as String?) ?? CashType.adjust,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        date: DateTime.fromMillisecondsSinceEpoch((m['date'] as num).toInt()),
        note: (m['note'] as String?) ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['created_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
        srcTxnId: (m['src_txn_id'] as num?)?.toInt(),
      );
}

/// 大盘指数（跑马灯用）
class MarketIndex {
  final String code; // 新浪格式，如 sh000001
  final String name;
  const MarketIndex(this.code, this.name);

  /// 预设的 A 股指数；默认只显示前 3 个
  ///
  /// `em:` 前缀表示「直接给东财的 secid」—— 上金所黄金、期货这类品种不属于
  /// 沪深两市，`sh/sz/bj` 那套推不出它们的 secid（黄金9999 是 `118.AU9999`，
  /// 沪金主连是 `113.aum`）。实测 `118.SHAU`（上海金基准价）**没有实时行情**
  /// （返回 0），所以这里用有连续报价的上金所现货 Au99.99。
  static const List<MarketIndex> presets = [
    MarketIndex('sh000001', '上证指数'),
    MarketIndex('sz399001', '深证成指'),
    MarketIndex('sz399006', '创业板指'),
    MarketIndex('sh000300', '沪深300'),
    MarketIndex('sh000688', '科创50'),
    MarketIndex('bj899050', '北证50'),
    MarketIndex('sh000905', '中证500'),
    MarketIndex('sh000016', '上证50'),
    MarketIndex('em:118.AU9999', '黄金9999'),
    MarketIndex('em:113.aum', '沪金主连'),
  ];

  static const List<String> defaultCodes = ['sh000001', 'sz399001', 'sz399006'];

  /// 上证指数：状态栏固定显示它，所以即使没勾进跑马灯也会照常拉取
  static const String shanghaiCode = 'sh000001';

  static MarketIndex? byCode(String code) {
    for (final p in presets) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// 首页跑马灯里的一项：`代码` 或 `代码|名称`
///
/// 预设指数（[MarketIndex.presets]）只用代码就够了，名字从预设表里取；
/// 自己按代码加的指数没有预设名，所以允许把名字一起存下来
/// （留空就显示代码本身）。旧数据里只有代码，解析时按没有名字处理。
class MarketIndexEntry {
  final String code;
  final String name;

  const MarketIndexEntry(this.code, [this.name = '']);

  /// 存进设置串的形式
  String get raw => name.isEmpty ? code : '$code|$name';

  @override
  String toString() => raw;
}

/// 解析 `marketIndices` 里的一个片段（容忍前后空格与多余分隔）
MarketIndexEntry parseIndexEntry(String raw) {
  final s = raw.trim();
  final i = s.indexOf('|');
  if (i < 0) return MarketIndexEntry(s);
  final code = s.substring(0, i).trim();
  final name = s.substring(i + 1).trim();
  return MarketIndexEntry(code, name);
}

/// 解析整串（逗号分隔，向后兼容只有代码的老数据）
List<MarketIndexEntry> parseIndexEntries(String? setting) {
  final out = <MarketIndexEntry>[];
  for (final part in (setting ?? '').split(',')) {
    final e = parseIndexEntry(part);
    if (e.code.isEmpty || out.any((x) => x.code == e.code)) continue;
    out.add(e);
  }
  return out;
}

/// 展示名：预设名优先 → 自定义名 → 代码
String indexDisplayName(String code, List<MarketIndexEntry> entries) {
  final preset = MarketIndex.byCode(code);
  if (preset != null) return preset.name;
  for (final e in entries) {
    if (e.code == code && e.name.isNotEmpty) return e.name;
  }
  return code;
}

// ============================================================
// 行情指标池（设置页「行情指标」）
// ============================================================

/// 池子里的一项：代码 / 全名 / 跑马灯简称 / 是否显示
///
/// 「待选」= 已经加进来了但没勾上（`on == false`）。
class IndexEntry {
  final String code;

  /// 全名（本地基金库或在线查到的，可能为空）
  final String name;

  /// 跑马灯上显示的简称，用户可自定义；为空时退回全名/代码
  final String short;

  /// 是否显示在跑马灯
  final bool on;

  /// 标的类型：index / fund / etf / stock（决定价格几位小数、走哪个行情源）
  final String kind;

  const IndexEntry({
    required this.code,
    this.name = '',
    this.short = '',
    this.on = false,
    this.kind = '',
  });

  /// 指标大类：`broad` 大盘指数 / `sector` 行业指数 / `etf` 场内基金 /
  /// `other` 其他市场（上金所黄金、期货…）
  ///
  /// 由 `kind` 与预设表推出来，不必额外存字段：
  /// 各类各走各的行情通道（指数走新浪大盘指数、场内基金走东财）。
  /// `em:` 开头的必须单独一类 —— 它们的 secid 不是 `1.`/`0.` 开头，
  /// 混进沪深那两条路会被拼成错的市场号。
  String get group {
    if (code.startsWith('em:')) return 'other';
    if (kind == 'etf' || kind == 'stock' || kind == 'fund') return 'etf';
    for (final p in MarketIndex.presets) {
      if (p.code == code) return 'broad';
    }
    return 'sector';
  }

  String get label => short.isNotEmpty
      ? short
      : (name.isNotEmpty ? name : code);

  IndexEntry copyWith(
          {String? code, String? name, String? short, bool? on, String? kind}) =>
      IndexEntry(
        code: code ?? this.code,
        name: name ?? this.name,
        short: short ?? this.short,
        on: on ?? this.on,
        kind: kind ?? this.kind,
      );

  Map<String, Object?> toJson() =>
      {'code': code, 'name': name, 'short': short, 'on': on, 'kind': kind};

  static IndexEntry fromJson(Object? raw) {
    if (raw is! Map) return const IndexEntry(code: '');
    return IndexEntry(
      code: (raw['code'] ?? '').toString(),
      name: (raw['name'] ?? '').toString(),
      short: (raw['short'] ?? '').toString(),
      on: raw['on'] == true,
      kind: (raw['kind'] ?? '').toString(),
    );
  }

  /// 老数据迁移：`marketIndices` 里的每一项都是"在显示"的
  factory IndexEntry.fromLegacy(MarketIndexEntry e) {
    final preset = MarketIndex.byCode(e.code);
    final name = e.name.isNotEmpty ? e.name : (preset?.name ?? '');
    return IndexEntry(
      code: normalizeIndexCode(e.code),
      name: name,
      short: name.isNotEmpty ? name : e.code,
      on: true,
    );
  }
}

/// 代码规范化：补齐 `sh` / `sz` / `bj` 前缀
///
/// - 带前缀的（`sh000300` / `sz399006` / `hkHSI` / `gb_$dji`）原样返回（转小写）
/// - 6 位纯数字：5/6/9 开头 → `sh`，4/8 开头 → `bj`，其余（0/1/2/3）→ `sz`
/// - 注意 `000001` 这种**既像上证指数又像平安银行**的代码，不加前缀就按深市（平安银行）算；
///   要上证指数请写 `sh000001`
String normalizeIndexCode(String raw) {
  final s = raw.trim().replaceAll(' ', '');
  if (s.isEmpty) return s;
  final lower = s.toLowerCase();
  // 已经是带前缀的形式：A 股的统一小写，港美股保持原样（hkHSI / gb_$dji 区分大小写）
  if (RegExp(r'^(sh|sz|bj)').hasMatch(lower)) return lower;
  if (RegExp(r'^(hk|gb_|us)').hasMatch(lower)) return s;
  if (RegExp(r'^\d{6}$').hasMatch(s)) {
    final c = s[0];
    if (c == '5' || c == '6' || c == '9') return 'sh$s';
    if (c == '4' || c == '8') return 'bj$s';
    return 'sz$s';
  }
  return s;
}

/// 这个代码是"指数"吗？（决定用哪个行情源）
///
/// `sh000xxx`（上证系列指数）、`sz399xxx`（深证系列指数）、`bj899xxx`（北证指数）
/// 走新浪精简行情；其余（`sh5xxxxx`/`sz1xxxxx` 的 ETF、6 位股票）走东财 push2。
bool isIndexLikeCode(String code) =>
    RegExp(r'^(sh000|sz399|bj899)').hasMatch(normalizeIndexCode(code));

/// 从全名里截一个跑马灯简称：去掉"ETF/基金/联接/发起式"这些噪音，最多 6 个字
String defaultIndexShort(String name) {
  var s = name.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll(
      RegExp(r'(ETF联接|ETF|LOF|QDII|联接|链接|发起式|指数基金|指数|证券投资基金|基金)'), '');
  s = s.replaceAll(RegExp(r'[（(].*?[）)]'), '');
  // 常见指数关键词优先：'沪深300ETF华泰柏瑞' → '沪深300'
  final kw = RegExp(
          r'^(沪深\d{3}|中证\d{3,4}|上证\d{2,3}|深证\d{2,3}|科创\d{2,3}|创业板|北证\d{2,3}|恒生\S{0,4}|标普\S{0,4}|纳斯达克\S{0,4})')
      .firstMatch(s);
  if (kw != null) return kw.group(1)!;
  if (s.length > 6) s = s.substring(0, 6);
  return s;
}

/// 解析设置里的池子 JSON（坏数据直接跳过）
List<IndexEntry> parseIndexPool(String? jsonText) {
  if (jsonText == null || jsonText.trim().isEmpty) return const [];
  try {
    final raw = jsonDecode(jsonText);
    if (raw is! List) return const [];
    final out = <IndexEntry>[];
    for (final item in raw) {
      final e = IndexEntry.fromJson(item);
      if (e.code.isEmpty) continue;
      if (out.any((x) => x.code == e.code)) continue;
      out.add(e);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

String encodeIndexPool(List<IndexEntry> list) =>
    jsonEncode([for (final e in list) e.toJson()]);

/// 收益表的一行：关注项 + 最新净值 + 各区间收益
class WatchRow {
  final WatchItem item;
  final double? nav;

  /// 最新净值所属日期（`yyyy-MM-dd`），关注表在净值下方显示它的 `MM-dd`
  final String? navDate;
  final Map<String, double?> returns; // ReturnPeriod.name -> %
  final int navCount;

  const WatchRow({
    required this.item,
    required this.nav,
    this.navDate,
    required this.returns,
    this.navCount = 0,
  });
}

/// 一个指数的实时行情
class IndexQuote {
  final String code;
  final String name;
  final double price;
  final double change;
  final double changePct;

  /// 价格显示几位小数：**基金（含 ETF）4 位**、指数 / 股票 2 位
  final int priceDigits;

  const IndexQuote({
    required this.code,
    required this.name,
    required this.price,
    required this.change,
    required this.changePct,
    this.priceDigits = 2,
  });
}

/// 这类指标的价格显示几位小数（基金按净值报，4 位；指数/股票 2 位）
int priceDigitsForKind(String kind) =>
    (kind == 'fund' || kind == 'etf') ? 4 : 2;
