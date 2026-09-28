/// 同花顺「A 股资料」三接口的模型与解析（**股票专用**，基金没有这些）：
///
/// - `/api/a-share/valuations/snapshot` —— 估值（**带中文名** + PE/PB/PS/PCF，
///   `thscodes` 逗号批量）
/// - `/api/a-share/financials/indicators` —— 财务指标（按 `report` 报告期，
///   返回 growth / profitability / solvency / operation / cash-flow 五组，
///   每组 `indicators[{index_id, value}]`）
/// - `/api/a-share/corporate-actions/adjustment-factors` —— 分红送配事件
///   （`ex_date_ms` / `dividend_per_share` / `per_share_bonus`）
///
/// 为什么单独一个文件：这三个都是**点进去才拉**的详情接口（同花顺有配额
/// `/api/quota/*`），与行情快照那套 60 秒轮询无关；解析放在这里就能脱离网络单测。
///
/// 字段名以 **2026-09-28 真 Key 实测**为准（000001.SZ / 600519.SH）：
/// ①估值接口**返回中文名** `name`（行情快照那套不返回），且**逗号批量可用**；
/// ②`report` **确实生效**（2025-1 / 2025-2 / 2026-1 / 2026-2 的数值各不相同，
///   实测营收同比 −13.05 → −10.04 → … → +1.78）；
/// ③**注意场外基金码会被拒**（`021362.OF` → `1002`），所以这个文件只服务股票/指数；
/// ④文档里 `/api/a-share/corporate-actions`（无 `/adjustment-factors`）**实测 404**，
///   只有带后缀的那条通。
///
/// 指标中文名：只认**官方文档收录**的名字（见 [kFinIndicatorLabels]）；
/// 文档没收录的（`calculate_*` 等 4 项）另放 [kFinIndicatorExtra]，
/// 界面上会带 ★ 标注如实说明，**不冒充官方口径**。
library;

/// 数值：字段缺失/为 null 时是 null（与「真的是 0」区分开）
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

// ── 估值 ────────────────────────────────────────────────────────────────────

/// 估值快照（`/api/a-share/valuations/snapshot` 的 `data.item[0]`）
///
/// 实测字段：`thscode / ticker / name / pe_ttm / pe_mrq / pb_mrq / ps_ttm / pcf_ttm`。
/// `name` 是**中文名**（平安银行 / 贵州茅台）—— 这是行情快照拿不到的东西。
class StockValuation {
  final String thscode;
  final String ticker;

  /// 中文名（实测有；没有就空串）
  final String name;

  /// 市盈率 TTM
  final double? peTtm;

  /// 市盈率（最新报告期 MRQ）
  final double? peMrq;

  /// 市净率 MRQ
  final double? pbMrq;

  /// 市销率 TTM
  final double? psTtm;

  /// 市现率 TTM
  final double? pcfTtm;

  const StockValuation({
    required this.thscode,
    required this.ticker,
    required this.name,
    this.peTtm,
    this.peMrq,
    this.pbMrq,
    this.psTtm,
    this.pcfTtm,
  });

  /// 有没有一个能看的数（全 null 就等于没取到）
  bool get isEmpty =>
      peTtm == null &&
      peMrq == null &&
      pbMrq == null &&
      psTtm == null &&
      pcfTtm == null;

  static StockValuation? fromJson(Map json) {
    final list = _itemList(json);
    if (list.isEmpty) return null;
    final j = list.first;
    return StockValuation(
      thscode: _str(j['thscode']),
      ticker: _str(j['ticker']),
      name: _str(j['name']),
      peTtm: _numOrNull(j['pe_ttm']),
      peMrq: _numOrNull(j['pe_mrq']),
      pbMrq: _numOrNull(j['pb_mrq']),
      psTtm: _numOrNull(j['ps_ttm']),
      pcfTtm: _numOrNull(j['pcf_ttm']),
    );
  }
}

// ── 财务指标 ────────────────────────────────────────────────────────────────

/// 一条财务指标：`index_id` 是**英文键**（如 `assets_debt_ratio`），
/// `value` 服务端保留原始字符串（百分比类按百分数、倍数类按倍数），
/// 这里同时留 [raw] 字符串与 [num] 数值：认不出的格式宁可显示原文，也不猜。
class StockIndicator {
  final String indexId;
  final String raw;
  final double? num;

  const StockIndicator({
    required this.indexId,
    required this.raw,
    required this.num,
  });
}

/// 一组能力（growth / profitability / solvency / operation / cash-flow）
class StockAbility {
  final String ability;
  final List<StockIndicator> indicators;

  const StockAbility({required this.ability, required this.indicators});

  /// 去掉值为空的那些（银行没有「存货周转率」，实测大量 null）
  List<StockIndicator> get nonNull =>
      [for (final i in indicators) if (i.raw.isNotEmpty) i];
}

/// 财务指标（`/api/a-share/financials/indicators`）
class StockFinancials {
  final String thscode;

  /// 报告期，实测形如 `2026-2`（年份-季度）
  final String report;
  final List<StockAbility> abilities;

  const StockFinancials({
    required this.thscode,
    required this.report,
    required this.abilities,
  });

  bool get isEmpty => abilities.every((a) => a.nonNull.isEmpty);

  StockIndicator? indicator(String indexId) {
    for (final a in abilities) {
      for (final i in a.indicators) {
        if (i.indexId == indexId) return i;
      }
    }
    return null;
  }

  static StockFinancials fromJson(Map json) {
    final d = _dataOf(json);
    final raw = d['abilities'];
    final list = <StockAbility>[];
    if (raw is List) {
      for (final a in raw) {
        if (a is! Map) continue;
        final inds = <StockIndicator>[];
        final arr = a['indicators'];
        if (arr is List) {
          for (final i in arr) {
            if (i is! Map) continue;
            final id = _str(i['index_id']);
            if (id.isEmpty) continue;
            final v = i['value'];
            inds.add(StockIndicator(
              indexId: id,
              raw: _str(v),
              num: _numOrNull(v),
            ));
          }
        }
        list.add(StockAbility(
          ability: _str(a['ability']),
          indicators: inds,
        ));
      }
    }
    return StockFinancials(
      thscode: _str(d['thscode']),
      report: _str(d['report']),
      abilities: list,
    );
  }
}

/// 报告期候选（**从"上一个已披露季度"往回退**，最多 6 个）
///
/// 实测每期都能返回 24 项指标、且数值随报告期变化，所以取第一个有数据的最稳；
/// 不写死 `2026-2`：跨年后端会变，往回试比写死强。
List<String> stockReportCandidates(DateTime now) {
  final q = ((now.month - 1) ~/ 3) + 1; // 1..4
  final out = <String>[];
  var y = now.year;
  var cur = q - 1; // 先试上一个季度（当期通常还没披露）
  if (cur < 1) {
    cur = 4;
    y -= 1;
  }
  for (var i = 0; i < 6; i++) {
    out.add('$y-$cur');
    cur -= 1;
    if (cur < 1) {
      cur = 4;
      y -= 1;
    }
  }
  return out;
}

/// 官方文档收录的「指数 id → 中文名」（20 条，2026-09-28 从
/// `fuyao.aicubes.cn/llms-full.txt` 的指标表里抠出来的）
const Map<String, String> kFinIndicatorLabels = {
  'total_assets_growth_ratio': '总资产增长率',
  'total_assets_net_ratio': '总资产收益率',
  'index_deduct_weighted_avg_roe': '扣非加权净资产收益率',
  'sale_gross_margin': '销售毛利率',
  'sale_net_interest_ratio': '销售净利率',
  'index_weighted_avg_roe': '净资产收益率',
  'current_ratio': '流动比率',
  'cash_ratio': '现金比率',
  'quick_ratio': '速动比率',
  'earned_interest_multiple': '已获利息倍数',
  'assets_debt_ratio': '资产负债率',
  'total_assets_turnover_ratio': '总资产周转率',
  'inventory_turnover_ratio': '存货周转率',
  'long_term_debt_equity_ratio': '长期负债权益比率',
  'current_assets_turnover_ratio': '流动资产周转率',
  'receive_account_turnover_ratio': '应收账款周转率',
  'net_profit_cash_content': '净利润现金含量',
  'cash_operating_index': '现金营运指数',
  'operating_cash_flow_net_divide_income': '销售现金比率',
  'cash_meet_invest_ratio': '现金满足投资比率',
};

/// 文档**没有**收录中文名的（4 条）：名字按接口 id 自身的英文含义给，
/// 界面上带 ★ 说明"非官方口径"，**不冒充**。
///
/// ⚠️ 实测这批 id **和文档表里写的不是一套**：文档写的是不带前缀的
/// `operating_income_yoy_growth_ratio` / `operating_profit_yoy_growth_ratio` /
/// `net_profit_yoy_growth_ratio`，而接口实际返回的是带 `calculate_` 前缀、
/// 且第三个叫 `calculate_parent_holder_net_profit_yoy_growth_ratio`（归母）。
/// 这是同花顺文档与实测的第 4 处不一致 —— 所以这几个只按 id 含义定名并标注。
const Map<String, String> kFinIndicatorExtra = {
  'calculate_operating_income_yoy_growth_ratio': '营业收入同比增速',
  'calculate_operating_profit_yoy_growth_ratio': '营业利润同比增速',
  'calculate_parent_holder_net_profit_yoy_growth_ratio': '归母净利润同比增速',
  'fixed_asset_invest_expansion_ratio': '固定资产投资扩张率',
};

/// 一行要显示的指标
class FinRow {
  final String indexId;
  final String label;

  /// true = 官方文档未收录中文名（界面加 ★）
  final bool unofficial;

  /// true = **百分比类**，界面补 `%`
  ///
  /// 依据是官方文档对 `value` 的说明：「百分比类指标按百分数值表达，
  /// 例如 `89.12000000` 表示 `89.12%`；周转率、比率、倍数类指标按指标名称
  /// 对应单位解释」。所以只有"增长率 / 收益率 / 毛利率 / 净利率 / 负债率"
  /// 这一类补 `%`；流动比率、周转率、倍数、指数、含量这些**不补单位**。
  final bool percent;

  const FinRow(this.indexId, this.label,
      {this.unofficial = false, this.percent = false});
}

/// 一组指标的显示配置
class FinGroup {
  /// 接口里的能力键
  final String ability;

  /// 组的中文名
  final String title;
  final List<FinRow> rows;

  const FinGroup(this.ability, this.title, this.rows);
}

/// 界面上显示哪些指标（每组 3 条，**只挑实测有值、含义明确的**；
/// 银行类没有的存货/流动比率等照配置请求，**值为空时界面自动跳过**）
const List<FinGroup> kFinGroups = [
  FinGroup('growth', '成长', [
    FinRow('calculate_operating_income_yoy_growth_ratio', '营业收入同比增长率',
        unofficial: true, percent: true),
    FinRow('calculate_parent_holder_net_profit_yoy_growth_ratio', '归母净利润同比增长率',
        unofficial: true, percent: true),
    FinRow('total_assets_growth_ratio', '总资产增长率', percent: true),
  ]),
  FinGroup('profitability', '盈利', [
    FinRow('index_weighted_avg_roe', '净资产收益率', percent: true),
    FinRow('index_deduct_weighted_avg_roe', '扣非加权净资产收益率', percent: true),
    FinRow('sale_net_interest_ratio', '销售净利率', percent: true),
  ]),
  FinGroup('solvency', '偿债', [
    FinRow('assets_debt_ratio', '资产负债率', percent: true),
    FinRow('current_ratio', '流动比率'),
    FinRow('quick_ratio', '速动比率'),
  ]),
  FinGroup('operation', '营运', [
    FinRow('total_assets_turnover_ratio', '总资产周转率'),
    FinRow('inventory_turnover_ratio', '存货周转率'),
    FinRow('receive_account_turnover_ratio', '应收账款周转率'),
  ]),
  FinGroup('cash-flow', '现金流', [
    FinRow('net_profit_cash_content', '净利润现金含量'),
    FinRow('operating_cash_flow_net_divide_income', '销售现金比率'),
    FinRow('cash_meet_invest_ratio', '现金满足投资比率'),
  ]),
];

// ── 分红送配 ────────────────────────────────────────────────────────────────

/// 一次分红送配事件（`adjustment-factors` 的 `data.item[]`）
///
/// 实测字段：`ex_date_ms`（除权除息日）/ `dividend_per_share`（每股分红，元）/
/// `per_share_bonus`（每股送股，股）。别的事件类型（配股等）字段名不同，
/// 这里只在字段存在时读，读不到留 null。
class StockDividendEvent {
  final DateTime? exDate;
  final double? dividendPerShare;
  final double? perShareBonus;

  const StockDividendEvent({
    this.exDate,
    this.dividendPerShare,
    this.perShareBonus,
  });

  /// 这条有没有可显示的内容
  bool get isEmpty =>
      (dividendPerShare == null || dividendPerShare == 0) &&
      (perShareBonus == null || perShareBonus == 0);
}

/// 解析分红送配事件，按除权日**从新到旧**排（最新的在前）
List<StockDividendEvent> parseStockDividendEvents(Map json) {
  final out = <StockDividendEvent>[];
  for (final j in _itemList(json)) {
    final e = StockDividendEvent(
      exDate: _dt(j['ex_date_ms']),
      dividendPerShare: _numOrNull(j['dividend_per_share']),
      perShareBonus: _numOrNull(j['per_share_bonus']),
    );
    if (e.isEmpty && e.exDate == null) continue;
    out.add(e);
  }
  out.sort((a, b) {
    final da = a.exDate, db = b.exDate;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  });
  return out;
}

// ── 打包 ────────────────────────────────────────────────────────────────────

/// 股票资料页的一次取数结果
///
/// 三块各自可能失败：**"没取到"和"没有"必须分开说** —— 接口挂了不能写成
/// 「该股没有分红」，所以每块都挂一个 error 字段（与基金档案页同一套规矩）。
class StockDetailBundle {
  final String code;

  final StockValuation? valuation;
  final StockFinancials? financials;
  final List<StockDividendEvent> dividends;

  final String? valuationError;
  final String? financialsError;
  final String? dividendsError;

  final DateTime fetchedAt;

  const StockDetailBundle({
    required this.code,
    this.valuation,
    this.financials,
    this.dividends = const [],
    this.valuationError,
    this.financialsError,
    this.dividendsError,
    required this.fetchedAt,
  });

  /// **三块全空** → 界面降级成「只看历史净值」
  bool get hasNothing =>
      valuation == null && financials == null && dividends.isEmpty;

  /// 带 ★ 的指标是否出现在这份数据里（界面上补一句说明用）
  bool get hasUnofficialIndicators {
    final f = financials;
    if (f == null) return false;
    for (final id in kFinIndicatorExtra.keys) {
      final ind = f.indicator(id);
      if (ind != null && ind.raw.isNotEmpty) return true;
    }
    return false;
  }
}
