/// 同花顺「基金详情」三接口的模型与解析（`fund/profile/detail`、
/// `fund/portfolio/holdings`、`fund/corporate-actions/dividends`）。
///
/// 为什么单独一个文件：这三个是**点进去才拉**的详情类接口（同花顺有配额
/// `/api/quota/*`），与行情快照那套 60 秒轮询无关；把解析放在这里就可以
/// 脱离网络单测（`test/fund_detail_test.dart`）。
///
/// 字段名以 **2026-09-23 真 Key 实测**为准 —— 文档站与实测有三处不一致，
/// 所以这里只认实测见过的字段，取不到的一律留 null，**不猜**。
library;

import '../core/format.dart';

/// 数值：字段缺失/为 null 时是 null（与「真的是 0」区分开，见 [FundProfile.unitNav]）
double? _numOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _intOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

DateTime? _dt(Object? v) {
  final ms = _intOrNull(v);
  if (ms == null || ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

/// 信封里的 `data` 段（不是 Map 就当空 Map）
Map<String, dynamic> _dataOf(Map json) {
  final d = json['data'];
  return d is Map ? Map<String, dynamic>.from(d) : const {};
}

/// `data.item` 列表（不是 List 就当空）
List<Map<String, dynamic>> _itemList(Map json) {
  final arr = _dataOf(json)['item'];
  if (arr is! List) return const [];
  return [
    for (final e in arr)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

/// 详情类接口的单条记录：实测是 `data.item[0]`
Map<String, dynamic> _item0(Map json) {
  final list = _itemList(json);
  return list.isEmpty ? const {} : list.first;
}

/// 顶层与 `data` 两处都找（实测有的计数字段在 `data` 里、有的在外面）
Object? _pick(Map json, String key) {
  final d = _dataOf(json);
  if (d[key] != null) return d[key];
  return json[key];
}

/// 基金经理（`profile/detail` 的 `manager_info[]`）
class FundManager {
  final String id;
  final String name;

  /// 任职回报（%）
  final double? tenureReturnPct;

  /// 任职天数
  final int? tenureDays;

  final DateTime? startDate;

  const FundManager({
    required this.id,
    required this.name,
    this.tenureReturnPct,
    this.tenureDays,
    this.startDate,
  });

  factory FundManager.fromJson(Map<String, dynamic> j) => FundManager(
        id: _str(j['manager_id']),
        name: _str(j['manager_name']),
        tenureReturnPct: _numOrNull(j['tenure_return_pct']),
        tenureDays: _intOrNull(j['tenure_days']),
        startDate: _dt(j['start_date_ms']),
      );
}

/// 交易规则（`trade_rule[]`）：买入提交 / 确认份额 / 查询收益 各自的时间口径
class FundTradeRule {
  final String title;

  /// 如「今日15点后」
  final String displayTime;

  const FundTradeRule({required this.title, required this.displayTime});

  factory FundTradeRule.fromJson(Map<String, dynamic> j) => FundTradeRule(
        title: _str(j['title']),
        displayTime: _str(j['display_time']),
      );
}

/// 费率（`rate_info[]`）
///
/// ⚠️ **实测是字符串**：`"1.20%"` / `"0.12%"` / `"1000元/笔"`。
/// 早先按数字解析（`double.tryParse`）会把每一条都变成 null，
/// 界面上整列都是 `--` —— 而且测试打桩用了数字，压根测不出来。
/// 所以这里原样保留字符串：认不出的单位（元/笔）也照样显示。
///
/// `rate_type` 实测有五种：`purchase`（申购）/ `redemption`（赎回）/
/// `recurring_investment`（定投）/ `management`（管理费）/ `custody`（托管费）；
/// 只有申购/定投有 `discounted_rate`。
class FundRate {
  final String type;
  final String chargeMode;

  /// 如「100万元以下」；管理费/托管费这类没有档位的是空串
  final String condition;
  final String standardRate;
  final String discountedRate;

  const FundRate({
    required this.type,
    required this.chargeMode,
    required this.condition,
    this.standardRate = '',
    this.discountedRate = '',
  });

  factory FundRate.fromJson(Map<String, dynamic> j) => FundRate(
        type: _str(j['rate_type']),
        chargeMode: _str(j['charge_mode']),
        condition: _str(j['condition']),
        standardRate: _str(j['standard_rate']),
        discountedRate: _str(j['discounted_rate']),
      );

  /// 这条费率有没有可显示的东西
  bool get hasRate => standardRate.isNotEmpty || discountedRate.isNotEmpty;
}

/// 基金档案（`fund/profile/detail`）
class FundProfile {
  final String thscode;
  final String ticker;

  /// ⚠️ 实测只回了「中证A」这种**疑似截断**的名字，所以界面优先用本地名称
  final String name;

  final DateTime? estabDate;
  final String companyId;

  /// 基金公司
  final String companyName;
  final String managerName;

  /// 规模（同花顺原样，单位未知，按字符串显示）
  final String scale;
  final double? unitNav;

  final List<FundManager> managers;
  final List<FundTradeRule> tradeRules;
  final List<FundRate> rates;

  const FundProfile({
    required this.thscode,
    required this.ticker,
    required this.name,
    this.estabDate,
    this.companyId = '',
    this.companyName = '',
    this.managerName = '',
    this.scale = '',
    this.unitNav,
    this.managers = const [],
    this.tradeRules = const [],
    this.rates = const [],
  });

  factory FundProfile.fromJson(Map json) {
    final it = _item0(json);
    return FundProfile(
      thscode: _str(it['thscode']),
      ticker: _str(it['ticker']),
      name: _str(it['fund_name']),
      estabDate: _dt(it['estab_date']),
      companyId: _str(it['company_id']),
      companyName: _str(it['mgmt_name']),
      managerName: _str(it['manager_name']),
      scale: _str(it['fund_scale']),
      unitNav: _numOrNull(it['unit_nav']),
      managers: [
        for (final e in (it['manager_info'] is List ? it['manager_info'] as List : const []))
          if (e is Map) FundManager.fromJson(Map<String, dynamic>.from(e)),
      ],
      tradeRules: [
        for (final e in (it['trade_rule'] is List ? it['trade_rule'] as List : const []))
          if (e is Map) FundTradeRule.fromJson(Map<String, dynamic>.from(e)),
      ],
      rates: [
        for (final e in (it['rate_info'] is List ? it['rate_info'] as List : const []))
          if (e is Map) FundRate.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }

  /// 一条字段都没有 = 这个响应里没有档案（避免把空对象画成一张空卡）
  bool get isEmpty =>
      ticker.isEmpty &&
      name.isEmpty &&
      companyName.isEmpty &&
      managers.isEmpty &&
      tradeRules.isEmpty &&
      rates.isEmpty;

  /// 规模的可显示写法。
  ///
  /// 实测同花顺给的是**没有单位的纯数字**（`261682632.55`，按元读就是 2.62 亿）——
  /// 直接把 9 位数字铺在界面上没人读得出来，所以按「万/亿」紧凑显示；
  /// 万一哪天改回「12.34亿」这种带单位的字符串，就原样显示。
  String get scaleText {
    final t = scale.trim();
    if (t.isEmpty) return '';
    final v = double.tryParse(t);
    if (v == null || v.abs() < 10000) return t;
    return fmtCompact(v);
  }
}

/// 重仓股（`portfolio/holdings` 的 `data.item[]`）
class FundStockHolding {
  final String thscode;
  final String ticker;
  final String name;

  /// 占净值比（%）
  final double? holdRatio;
  final double? positionCapital;
  final double? positionCount;

  /// 占股票投资市值比（%）
  final double? marketValueRatePct;

  /// 较上期变动（%）
  final double? periodIncreaseRatePct;
  final int? rank;

  /// 报告期
  final DateTime? publishDate;

  const FundStockHolding({
    required this.thscode,
    required this.ticker,
    required this.name,
    this.holdRatio,
    this.positionCapital,
    this.positionCount,
    this.marketValueRatePct,
    this.periodIncreaseRatePct,
    this.rank,
    this.publishDate,
  });

  factory FundStockHolding.fromJson(Map<String, dynamic> j) => FundStockHolding(
        thscode: _str(j['thscode']),
        ticker: _str(j['ticker']),
        name: _str(j['stock_name']),
        holdRatio: _numOrNull(j['hold_ratio']),
        positionCapital: _numOrNull(j['position_capital']),
        positionCount: _numOrNull(j['position_count']),
        marketValueRatePct: _numOrNull(j['security_market_value_rate_pct']),
        periodIncreaseRatePct: _numOrNull(j['period_increase_rate_pct']),
        rank: _intOrNull(j['investment_rank']),
        publishDate: _dt(j['publish_date_ms']),
      );
}

/// 基金持仓概览 + 重仓股（`portfolio/holdings`）
class FundPortfolio {
  /// 股票总仓位（%）
  final double? totalStockRatioPct;

  /// 股票占净值比（%）
  final double? stockRatioPct;

  /// 主要行业
  final String mainIndustry;

  /// 集中度（0~1）
  final double? concentrationRatio;

  final List<FundStockHolding> holdings;

  const FundPortfolio({
    this.totalStockRatioPct,
    this.stockRatioPct,
    this.mainIndustry = '',
    this.concentrationRatio,
    this.holdings = const [],
  });

  factory FundPortfolio.fromJson(Map json) {
    final d = _dataOf(json);
    return FundPortfolio(
      totalStockRatioPct: _numOrNull(d['total_stock_ratio_pct']),
      stockRatioPct: _numOrNull(d['stock_ratio_pct']),
      mainIndustry: _str(d['main_industry']),
      concentrationRatio: _numOrNull(d['concentration_ratio']),
      holdings: [
        for (final e in _itemList(json)) FundStockHolding.fromJson(e),
      ],
    );
  }

  /// 报告期：取重仓股里最新的那个
  DateTime? get publishDate {
    DateTime? latest;
    for (final h in holdings) {
      final d = h.publishDate;
      if (d == null) continue;
      if (latest == null || d.isAfter(latest)) latest = d;
    }
    return latest;
  }

  bool get isEmpty =>
      holdings.isEmpty &&
      totalStockRatioPct == null &&
      stockRatioPct == null &&
      mainIndustry.isEmpty;
}

/// 一条分红记录（`corporate-actions/dividends` 的 `data.item[]`）
class FundDividend {
  /// 每 10 份现金分红（税前 / 税后）
  final double? perTenBeforeTax;
  final double? perTenAfterTax;
  final String progress;

  final DateTime? publishDate;
  final DateTime? registrationDate;
  final DateTime? exDividendDate;
  final DateTime? paymentDate;

  /// 红利再投日
  final DateTime? reinvestmentDate;
  final DateTime? profitBaseDate;
  final DateTime? inDividendDate;

  const FundDividend({
    this.perTenBeforeTax,
    this.perTenAfterTax,
    this.progress = '',
    this.publishDate,
    this.registrationDate,
    this.exDividendDate,
    this.paymentDate,
    this.reinvestmentDate,
    this.profitBaseDate,
    this.inDividendDate,
  });

  factory FundDividend.fromJson(Map<String, dynamic> j) => FundDividend(
        perTenBeforeTax: _numOrNull(j['per_ten_cash_before_tax']),
        perTenAfterTax: _numOrNull(j['per_ten_cash_after_tax']),
        progress: _str(j['progress']),
        publishDate: _dt(j['publish_date_ms']),
        registrationDate: _dt(j['registration_date_ms']),
        exDividendDate: _dt(j['ex_dividend_date_ms']),
        paymentDate: _dt(j['payment_date_ms']),
        reinvestmentDate: _dt(j['reinvestment_date_ms']),
        profitBaseDate: _dt(j['profit_base_date_ms']),
        inDividendDate: _dt(j['in_dividend_date_ms']),
      );

  /// 有意义的日期：用于排序与「最近一次分红」
  DateTime? get keyDate =>
      exDividendDate ?? registrationDate ?? paymentDate ?? publishDate;

  /// 这一条到底有没有内容？
  ///
  /// **实测踩过**（021362，一只从没分过红的基金）：服务端会回一条
  /// **全 null 的占位记录** —— `dividend_count=0`，但 `item` 的长度是 1、
  /// 里面每个字段都是 null。不滤掉的话，页面会给一只没分过红的基金
  /// 画出一行空记录（除息日、每10份全是 `--`），看着像"有数据但显示不出来"。
  bool get hasData =>
      perTenBeforeTax != null ||
      perTenAfterTax != null ||
      progress.isNotEmpty ||
      keyDate != null;
}

/// 分红汇总（`corporate-actions/dividends`）
class FundDividends {
  /// 分红次数；字段缺失时为 null（不拿"列表长度"冒充总次数）
  final int? count;

  /// 累计分红（同花顺原样，单位未知，按字符串显示）
  final String total;

  final List<FundDividend> items;

  const FundDividends({this.count, this.total = '', this.items = const []});

  factory FundDividends.fromJson(Map json) {
    final raw = _pick(json, 'dividend_count');
    final total = _pick(json, 'dividend_total');
    return FundDividends(
      count: _intOrNull(raw),
      total: _str(total),
      items: _itemList(json)
          .map(FundDividend.fromJson)
          // 全 null 的占位记录（没分过红时服务端会给一条）在这里丢掉，
          // 否则界面上会多出一行空的分红记录
          .where((d) => d.hasData)
          .toList()
        ..sort((a, b) {
          final da = a.keyDate;
          final db = b.keyDate;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da); // 新的在前
        }),
    );
  }

  /// 一次分红都没有（`dividend_count = 0` 或列表为空）
  bool get isEmpty => items.isEmpty && (count == null || count == 0);

  /// 分红次数为 0 但**确实**问了服务端：可以放心说「暂无分红记录」
  bool get confirmedEmpty => count == 0 && items.isEmpty;

  /// 累计分红（同花顺原样）；空串或 0 都当作"没有"，不显示
  ///
  /// 实测没分过红的基金会回 `dividend_total: 0.0` —— 直接显示会变成
  /// 「累计分红：0.0」，容易被读成"分过 0 元"。
  String? get totalText {
    final t = total.trim();
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    if (v != null && v.abs() < 1e-9) return null;
    return t;
  }
}

/// 一只基金的档案 / 持仓 / 分红三块数据（页面一次要用的全部）
class FundDetailBundle {
  final FundProfile profile;

  final FundPortfolio? portfolio;
  final FundDividends? dividends;

  /// 哪一块没取到（null = 取到了）。**失败与"没有数据"必须分开说**
  final String? portfolioError;
  final String? dividendsError;

  final DateTime fetchedAt;

  const FundDetailBundle({
    required this.profile,
    required this.fetchedAt,
    this.portfolio,
    this.dividends,
    this.portfolioError,
    this.dividendsError,
  });
}

// thscode 的换算（`.OF` / 市场后缀）在 `hithink_api.dart` 的
// [HithinkApi.fundThscodeFor] 里 —— 号段规则只该有一处。
