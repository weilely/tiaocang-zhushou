import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import '../data/backup_store.dart';
import '../data/db.dart';
import '../data/dca_models.dart';
import '../data/dca_repo.dart';
import '../data/dca_source.dart';
import '../data/file_store.dart';
import '../data/market_api.dart';
import '../data/models.dart';
import '../data/nav_models.dart';
import '../data/nav_repo.dart';
import '../data/nav_source.dart';
import '../data/securities_repo.dart';
import '../data/securities_source.dart';
import '../logic/backup.dart';
import '../logic/benchmark.dart';
import '../logic/cash_flow.dart';
import '../logic/csv_io.dart';
import '../logic/dca.dart';
import '../logic/link_etf.dart';
import '../logic/nav_lookup.dart';
import '../logic/period_return.dart';
import '../logic/pinyin_util.dart';
import '../logic/portfolio.dart';
import '../logic/quote_sync.dart';
import '../logic/range_preset.dart';
import '../logic/rebalance_plan.dart';
import '../logic/returns_calendar.dart';

/// 收益统计卡片的三个页签
enum StatsView { calendar, trend, flow }

/// 全局应用状态：加载本地数据、拉取行情、计算持仓与再平衡
class AppState extends ChangeNotifier {
  final AppDatabase db = AppDatabase.instance;
  final MarketService market = MarketService();

  bool loading = true;
  bool refreshing = false;
  String? lastError;
  String? lastMessage;
  DateTime? lastRefresh;

  List<Account> accounts = [];
  List<Asset> assetList = [];
  Map<int, Asset> assetsById = {};
  List<Txn> txns = [];
  Map<String, Quote> quotes = {};
  List<TargetAlloc> targets = [];

  /// 再平衡告警阈值（0.05 = 5%）
  double threshold = 0.05;

  /// 账户筛选；null 表示全部账户
  int? accountFilter;

  /// 最近一次备份时间
  DateTime? lastBackupAt;

  /// 基础数据库（代码/名称/首拼/类型/板块）的下载源
  final SecuritiesSource securitiesSource = SecuritiesSource();

  /// 基础数据库更新中（禁用重复点击）
  bool securitiesBusy = false;

  /// 更新进度文案，如「第 12/56 页」
  String securitiesProgress = '';
  DateTime? securitiesUpdatedAt;
  int securitiesFundCount = 0;
  int securitiesStockCount = 0;

  /// 持仓列表排序键：marketValue | returnPct | dayPnl | cost
  String holdingsSortKey = 'marketValue';
  bool holdingsSortDesc = false;

  /// 定投计划与历史价格源
  final DcaPriceSource dcaSource = DcaPriceSource();
  List<DcaPlan> dcaPlans = [];

  /// 全局自动补记开关
  bool dcaAutoRun = true;

  /// 定投补记进行中
  bool dcaRunning = false;

  /// 关注（自选）与历史净值
  final NavSource navSource = NavSource();
  List<WatchItem> watchlist = [];

  /// code → 表格算区间收益用的净值样本（最早一条 + 近 5 年）
  Map<String, List<NavPoint>> navSamples = {};

  bool navUpdating = false;
  String navProgress = '';
  DateTime? navUpdatedAt;
  int navRowCount = 0;

  /// 现金（账户级流水，余额 = Σ金额）
  List<CashTxn> cashTxns = [];
  Map<int, double> cashBalances = {};

  /// 账户 → [当月收益, 累计收益]
  Map<int, List<double>> cashIncome = {};

  /// 大盘指数
  List<String> marketIndices = List.of(MarketIndex.defaultCodes);
  List<IndexQuote> indexQuotes = [];

  // ============================================================
  // 派生视图（getter 群）
  // ============================================================

  Map<int, Account> get accountsById =>
      {for (final a in accounts) if (a.id != null) a.id!: a};

  /// 当前账户筛选下的流水
  List<Txn> get txnsOfFilter => accountFilter == null
      ? txns
      : [for (final t in txns) if (t.accountId == accountFilter) t];

  /// 当前账户下的持仓（已按筛选）
  List<Position> get positions => buildPositions(
        txns: txnsOfFilter,
        assets: assetsById,
        quotes: quotes,
      );

  /// 所有账户的持仓（不受账户筛选影响；再平衡、总览用）
  List<Position> get allPositions => buildPositions(
        txns: txns,
        assets: assetsById,
        quotes: quotes,
      );

  /// 非空持仓（持仓页、调仓页用）
  List<Position> get holdings =>
      [for (final p in positions) if (!p.isEmpty) p];

  /// 按当前排序设置排好的持仓
  List<Position> get sortedHoldings {
    final list = List<Position>.of(holdings);
    double key(Position p) => switch (holdingsSortKey) {
          'returnPct' => p.floatingPct,
          'dayPnl' => p.dayPnl,
          'cost' => p.cost,
          _ => p.marketValue,
        };
    list.sort((a, b) {
      final r = key(a).compareTo(key(b));
      return holdingsSortDesc ? -r : r;
    });
    return list;
  }

  int get holdingCount => holdings.length;

  PortfolioSummary get summary => summarize(positions);

  /// 总市值 = 持仓市值 + 现金余额
  double get totalMarketValue => summary.marketValue + cashTotalValue;

  double get cashTotalValue {
    if (accountFilter != null) return cashBalances[accountFilter] ?? 0;
    return cashBalances.values.fold<double>(0, (a, b) => a + b);
  }

  List<AllocationSlice> get kindAllocation => allocationByKind(positions);

  List<AllocationSlice> get assetAllocation => allocationByAsset(positions);

  List<AllocationSlice> get accountAllocation =>
      allocationByAccount(positions, accountsById);

  /// 账面是否对得上（流水缺口/重影检测）
  bool get ledgerIncomplete => pnlCrossCheck != null;

  /// 某个标的在某账户下的持仓（详情页用）
  Position? positionOf(int accountId, int assetId) {
    for (final p in allPositions) {
      if (p.accountId == accountId && p.asset.id == assetId) return p;
    }
    return null;
  }

  // ============================================================
  // 账户
  // ============================================================

  Future<void> addAccount(String name, String note) async {
    final n = name.trim();
    if (n.isEmpty) return;
    await db.saveAccount(Account(name: n, note: note.trim()));
    accounts = await db.accounts();
    notifyListeners();
  }

  Future<void> updateAccount(Account a) async {
    await db.saveAccount(a);
    accounts = await db.accounts();
    notifyListeners();
  }

  Future<void> removeAccount(int id) async {
    await db.deleteAccount(id);
    accounts = await db.accounts();
    assetList = await db.assets();
    assetsById = {for (final a in assetList) if (a.id != null) a.id!: a};
    txns = await db.txns();
    cashTxns = await db.cashTxns();
    _recompute();
    if (accountFilter == id) accountFilter = null;
    notifyListeners();
  }

  void setAccountFilter(int? id) {
    accountFilter = id;
    _recompute();
    notifyListeners();
  }

  // ============================================================
  // 排序与视图开关
  // ============================================================

  Future<void> setHoldingsSort(String key, bool desc) async {
    holdingsSortKey = key;
    holdingsSortDesc = desc;
    await db.setSetting('holdingsSortKey', holdingsSortKey);
    await db.setSetting('holdingsSortDesc', holdingsSortDesc ? '1' : '0');
    notifyListeners();
  }

  void setStatsView(StatsView v) {
    statsView = v;
    notifyListeners();
  }



  // ============================================================
  // 标的
  // ============================================================

  /// 取（或新建）一只标的，返回它的 id
  /// 按名字取账户 id；不存在就新建（CSV 导入时按账户名关联）
  Future<int> ensureAccountByName(String name) async {
    final n = name.trim();
    if (n.isNotEmpty) {
      for (final a in accounts) {
        if (a.name == n && a.id != null) return a.id!;
      }
      final id = await db.saveAccount(Account(name: n, note: '导入自 CSV'));
      accounts = await db.accounts();
      return id;
    }
    for (final a in accounts) {
      if (a.id != null) return a.id!;
    }
    final id = await db.saveAccount(Account(name: '默认账户', note: ''));
    accounts = await db.accounts();
    return id;
  }

  /// 标的
  Future<Asset> ensureAsset(Asset a) async {
    final id = await db.upsertAsset(a);
    assetList = await db.assets();
    assetsById = {for (final x in assetList) if (x.id != null) x.id!: x};
    return a.copyWith(id: id);
  }


  // ============================================================
  // 记账（买入 / 卖出 / 分红）
  // ============================================================

  /// 记一笔并联动现金（详情页/记一笔表单用）
  Future<void> saveTxnWithCash(Txn t, Asset a, {bool linkCash = true}) async {
    final asset = await ensureAsset(a);
    final saved = t.copyWith(assetId: asset.id);
    final id = await db.saveTxn(saved);
    // 改一笔之前先清掉它上次联动出来的现金流水：
    // 否则每编辑一次就多插一条，现金余额会重复累加。
    if (id > 0) await db.deleteCashBySrcTxn(id);
    if (linkCash) await _linkCashFor(saved.copyWith(id: id));
    txns = await db.txns();
    cashTxns = await db.cashTxns();
    quotes = await db.quotes();
    _recompute();
    notifyListeners();
  }

  /// 记一笔并顺带建标的（期初持仓导入用，**不联动现金**）
  Future<void> saveTxnWithAsset(Txn t, Asset a) async {
    final id = await db.upsertAsset(a);
    await db.saveTxn(t.copyWith(assetId: id));
    assetList = await db.assets();
    assetsById = {for (final x in assetList) if (x.id != null) x.id!: x};
    txns = await db.txns();
    _recompute();
    notifyListeners();
  }

  Future<void> removeTxn(int id) async {
    // 联动出来的现金流水跟着一起删，别留下孤儿流水影响余额
    await db.deleteCashBySrcTxn(id);
    await db.deleteTxn(id);
    txns = await db.txns();
    cashTxns = await db.cashTxns();
    _recompute();
    notifyListeners();
  }

  /// 交易存在、但现金流水为空时，按交易**一次性重建**现金流水
  ///
  /// 早期版本（CSV 导入 / 期初持仓导入）只写了交易、没联动现金，
  /// 结果现金页和买卖完全脱节。这里只在"一条现金都没有"时补，
  /// 绝不动用户手动记的现金。
  Future<int> rebuildCashFromTxns() async {
    if (cashTxns.isNotEmpty || txns.isEmpty) return 0;
    var n = 0;
    for (final t in txns) {
      final sign = t.type == TxnType.buy ? -1.0 : 1.0;
      final amount =
          t.type == TxnType.buy ? t.amount + t.fee : t.amount - t.fee;
      if (amount == 0) continue;
      await db.saveCashTxn(CashTxn(
        accountId: t.accountId,
        type: t.type == TxnType.buy
            ? CashType.invest
            : (t.type == TxnType.sell ? CashType.redeem : CashType.dividend),
        amount: sign * amount,
        date: t.date,
      note: () {
        final code = assetsById[t.assetId]?.code ?? '';
        final s = code.isEmpty ? '' : displayShortOf(code);
        return s.isEmpty ? t.type.label : ' · ${t.type.label}';
      }(),
        createdAt: DateTime.now(),
        srcTxnId: t.id,
      ));
      n++;
    }
    cashTxns = await db.cashTxns();
    _recompute();
    if (n > 0) {
      lastMessage = '已按 $n 笔交易重建现金流水（之前只记了交易、没联动现金）';
    }
    notifyListeners();
    return n;
  }

  /// 买入/卖出/分红 → 现金流水（买入扣钱、卖出和分红进钱）
  Future<void> _linkCashFor(Txn t) async {
    final sign = switch (t.type) {
      TxnType.buy => -1.0,
      _ => 1.0,
    };
    final amount = t.type == TxnType.buy ? t.amount + t.fee : t.amount - t.fee;
    if (amount == 0) return;
    await db.saveCashTxn(CashTxn(
      accountId: t.accountId,
      type: t.type == TxnType.buy
          ? CashType.invest
          : (t.type == TxnType.sell ? CashType.redeem : CashType.dividend),
      amount: sign * amount,
      date: t.date,
      note: () {
        final code = assetsById[t.assetId]?.code ?? '';
        final s = code.isEmpty ? '' : displayShortOf(code);
        return s.isEmpty ? t.type.label : ' · ${t.type.label}';
      }(),
      createdAt: DateTime.now(),
      srcTxnId: t.id,
    ));
  }

  // ============================================================
  // 调仓目标（按具体标的）
  // ============================================================

  Future<void> setTargetRatio(String key, String label, double ratio) async {
    if (ratio <= 0) {
      await removeTarget(key);
      return;
    } else {
      await db.saveTarget(TargetAlloc(key: key, label: label, ratio: ratio));
    }
    targets = await db.targets();
    notifyListeners();
  }

  Future<void> removeTarget(String key) async {
    for (final t in targets) {
      if (t.key == key && t.id != null) {
        await db.deleteTarget(t.id!);
        break;
      }
    }
    targets = await db.targets();
    notifyListeners();
  }

  // ============================================================
  // 行情指标池
  // ============================================================

  List<IndexEntry> indexPool = [];

  /// 上次刷新跑马灯行情的结果（设置页「行情指标」里显示，用来定位取数问题）
  String indexQuoteDiag = '';

  List<IndexEntry> get activeIndexEntries =>
      [for (final e in indexPool) if (e.on) e];

  List<MarketIndexEntry> get marketIndexEntries => [
        for (final e in activeIndexEntries) MarketIndexEntry(e.code, e.label),
      ];

  /// 跑马灯要显示的行情（排除固定在标题栏的上证）

  /// 某个指标的类型（决定价格小数位、走哪个行情源）

  /// 某个代码在池子/预设里的展示名（跑马灯用）
  String _indexLabelOf(String code) {
    for (final e in indexPool) {
      if (e.code == code) return e.label;
    }
    return MarketIndex.byCode(code)?.name ?? code;
  }

  Future<void> loadMarketIndices() async {
    indexPool = parseIndexPool(await db.setting('marketIndexPool'));
    if (indexPool.isEmpty) {
      final s = await db.setting('marketIndices');
      if (s == null || s.trim().isEmpty) {
        indexPool = [
          for (final c in MarketIndex.defaultCodes)
            IndexEntry(
              code: c,
              name: MarketIndex.byCode(c)?.name ?? '',
              short: MarketIndex.byCode(c)?.name ?? c,
              kind: 'index',
              on: true,
            ),
        ];
      } else {
        indexPool = [
          for (final e in parseIndexEntries(s)) IndexEntry.fromLegacy(e),
        ];
      }
      await db.setSetting('marketIndexPool', encodeIndexPool(indexPool));
    }
    marketIndices = [for (final e in activeIndexEntries) e.code];

    final cache = await db.setting('indexQuotesCache');
    if (cache != null && cache.isNotEmpty) {
      try {
        final list = jsonDecode(cache);
        if (list is List) {
          indexQuotes = [
            for (final raw in list.whereType<Map>())
              IndexQuote(
                code: (raw['c'] ?? '').toString(),
                name: (raw['n'] ?? '').toString(),
                price: (raw['p'] as num?)?.toDouble() ?? 0,
                change: 0,
                changePct: (raw['d'] as num?)?.toDouble() ?? 0,
              ),
          ];
        }
      } catch (_) {
        // 缓存坏了无所谓
      }
    }
    notifyListeners();
  }

  Future<void> saveIndexPool() async {
    await db.setSetting('marketIndexPool', encodeIndexPool(indexPool));
    marketIndices = [for (final e in activeIndexEntries) e.code];
    await db.setSetting(
        'marketIndices',
        [for (final e in activeIndexEntries) '${e.code}|${e.label}'].join(','));
    notifyListeners();
    unawaited(refreshIndexQuotes());
  }

  /// 按代码加一个指标（已存在就更新名字/简称），默认进「待选」
  Future<void> addIndexEntry(IndexEntry entry, {bool on = false}) async {
    final code = normalizeIndexCode(entry.code);
    if (code.isEmpty) return;
    final next = entry.copyWith(code: code, on: on);
    indexPool = [
      for (final e in indexPool)
        if (e.code != code) e,
      next,
    ];
    await saveIndexPool();
  }

  Future<void> toggleIndexEntry(String code) async {
    indexPool = [
      for (final e in indexPool) e.code == code ? e.copyWith(on: !e.on) : e,
    ];
    await saveIndexPool();
  }

  Future<void> removeIndexEntry(String code) async {
    indexPool = [for (final e in indexPool) if (e.code != code) e];
    await saveIndexPool();
  }

  Future<void> renameIndexEntry(String code, String short) async {
    indexPool = [
      for (final e in indexPool)
        e.code == code ? e.copyWith(short: short.trim()) : e,
    ];
    await saveIndexPool();
  }

  Future<void> addMarketIndex(String code, String name) async {
    final c = normalizeIndexCode(code);
    if (c.isEmpty) return;
    await addIndexEntry(
      IndexEntry(code: c, name: name, short: name, kind: 'index'),
      on: true,
    );
  }

  Future<void> setMarketIndices(List<String> codes) async {
    indexPool = [
      for (final raw in codes) IndexEntry.fromLegacy(parseIndexEntry(raw)),
    ];
    if (indexPool.isEmpty) {
      indexPool = [
        for (final c in MarketIndex.defaultCodes)
          IndexEntry(
            code: c,
            name: MarketIndex.byCode(c)?.name ?? '',
            short: MarketIndex.byCode(c)?.name ?? c,
            kind: 'index',
            on: true,
          ),
      ];
    }
    await saveIndexPool();
  }

  // ============================================================
  // 基准 / 趋势 / 日历 / 资金流
  // ============================================================

  Benchmark benchmark = kDefaultBenchmark;
  RangePreset trendPreset = RangePreset.m6;
  DateTime? trendCustomStart;
  DateTime? trendCustomEnd;
  RangePreset flowPreset = RangePreset.y1;
  DateTime? flowCustomStart;
  DateTime? flowCustomEnd;
  StatsView statsView = StatsView.calendar;
  ReturnGranularity calendarGranularity = ReturnGranularity.month;
  /// 日历当前月份（UI 里是 ({int month, int year}) 记录）
  ({int month, int year}) calendarCursor =
      (year: DateTime.now().year, month: DateTime.now().month);

  Future<void> setBenchmark(Benchmark b) async {
    benchmark = b;
    for (final e in b.toSettings().entries) {
      await db.setSetting(e.key, e.value);
    }
    notifyListeners();
  }

  void setTrendPreset(RangePreset p) {
    trendPreset = p;
    notifyListeners();
  }

  void setTrendCustomRange(DateTime start, DateTime end) {
    trendCustomStart = start;
    trendCustomEnd = end;
    trendPreset = RangePreset.custom;
    notifyListeners();
  }

  void setFlowPreset(RangePreset p) {
    flowPreset = p;
    notifyListeners();
  }

  void setFlowCustomRange(DateTime start, DateTime end) {
    flowCustomStart = start;
    flowCustomEnd = end;
    flowPreset = RangePreset.custom;
    notifyListeners();
  }

  void setCalendarGranularity(ReturnGranularity p) {
    calendarGranularity = p;
    notifyListeners();
  }

  void setCalendarCursor(int year, int month) {
    calendarCursor = (year: year, month: month);
    notifyListeners();
  }

  // ============================================================
  // 生命周期
  // ============================================================

  Future<void> init() async {
    loading = true;
    notifyListeners();
    try {
      await _loadFromDb();
      threshold = await db.settingDouble('threshold', 0.05);
      holdingsSortKey = await db.setting('holdingsSortKey') ?? 'marketValue';
      holdingsSortDesc = (await db.setting('holdingsSortDesc') ?? '0') == '1';
      dcaAutoRun = (await db.setting('dcaAutoRun') ?? '1') == '1';
      final savedView = await db.setting('statsView');
      statsView = StatsView.values.firstWhere(
        (v) => v.name == savedView,
        orElse: () => StatsView.calendar,
      );
      benchmark = Benchmark.fromSettings(
        await db.setting('benchmarkKind'),
        await db.setting('benchmarkAnnualPct'),
        await db.setting('benchmarkIndexCode'),
        await db.setting('benchmarkIndexName'),
      );
      await loadSecuritiesStats();
    } catch (e) {
      lastError = '本地数据加载失败：$e';
    } finally {
      loading = false;
      _recompute();
    }
    // 先读池子与缓存，再拉行情：否则首次刷新可能先跑完，
    // 把缓存里的指标覆盖成「只有上证」，跑马灯就空了
    unawaited(loadMarketIndices().then((_) => refreshIndexQuotes()));
    unawaited(refreshQuotes(silent: true));
    unawaited(autoBackupIfNeeded());
    unawaited(runDueDca());
    // 先读现金；若一条都没有而交易不少，说明是老数据，按交易补一次联动
    unawaited(loadCash().then((_) => rebuildCashFromTxns()));
    unawaited(loadAssetShorts());
    unawaited(loadBiometric());
    unawaited(loadNavSamples());
  }

  /// 重新算派生数据（现金余额/收益、逐日序列缓存作废）
  void _recompute() {
    final balances = <int, double>{};
    for (final c in cashTxns) {
      balances[c.accountId] = (balances[c.accountId] ?? 0) + c.amount;
    }
    cashBalances = balances;
    cashIncome = _cashIncomeOf(cashTxns);
    _invalidateSeries();
  }

  // ============================================================
  // 行情刷新（持仓 + 关联 ETF）
  // ============================================================

  /// 被持有过的标的（用于刷新行情）
  List<Asset> get trackedAssets {
    final ids = txns.map((t) => t.assetId).toSet();
    return [
      for (final a in assetList)
        if (a.id != null && ids.contains(a.id)) a,
    ];
  }

  /// 只为估涨幅而临时合成的关联 ETF（**没有 id**，不能拿去写库）
  List<Asset> get linkAssets {
    final out = <Asset>[];
    final seen = <String>{};
    for (final a in trackedAssets) {
      final link = a.linkCode.trim();
      if (link.isEmpty || !seen.add(link)) continue;
      out.add(Asset(
        code: link,
        name: '',
        kind: AssetKind.etf,
        market: MarketService.marketFor(link),
      ));
    }
    return out;
  }

  /// 关联 ETF 的实时行情
  Map<String, Quote> get linkQuotes {
    final out = <String, Quote>{};
    for (final a in linkAssets) {
      final q = quotes[a.code];
      if (q != null) out[a.code] = q;
    }
    return out;
  }

  Future<void> setAssetLink(int assetId, String linkCode) async {
    await db.updateAssetLink(assetId, linkCode.trim());
    assetList = await db.assets();
    assetsById = {for (final x in assetList) if (x.id != null) x.id!: x};
    notifyListeners();
    unawaited(refreshQuotes(silent: true));
  }

  /// 给「还没设关联 ETF 的场外基金」自动猜一只场内 ETF 并记下来
  Future<int> ensureLinkEtfs({bool force = false}) async {
    if (force) _linkTried.clear();
    final todo = trackedAssets
        .where((a) =>
            a.kind == AssetKind.fund &&
            a.linkCode.trim().isEmpty &&
            a.id != null &&
            !_linkTried.contains(a.code))
        .toList();
    if (todo.isEmpty) return 0;

    var matched = 0;
    for (final a in todo) {
      _linkTried.add(a.code);
      final name = a.name.trim().isEmpty ? a.code : a.name;
      final candidates = <String, String>{};
      for (final kw in fundLinkKeywords(name)) {
        if (candidates.length >= 24) break;
        try {
          final rows = await market.search(kw);
          for (final r in rows) {
            if (isExchangeEtfCode(r.code) && r.name.isNotEmpty) {
              candidates[r.code] = r.name;
            }
          }
        } catch (_) {
          // 联网失败就换下一个关键词
        }
        if (pickLinkEtf(name, candidates) != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final best = pickLinkEtf(name, candidates);
      if (best != null) {
        await db.updateAssetLink(a.id!, best.code);
        matched++;
      }
    }
    if (matched > 0) {
      assetList = await db.assets();
      assetsById = {for (final x in assetList) if (x.id != null) x.id!: x};
      notifyListeners();
    }
    return matched;
  }

  final Set<String> _linkTried = {};

  Future<void> refreshQuotes({bool silent = false}) async {
    if (refreshing) return;
    final need = [...trackedAssets, ...linkAssets];
    if (need.isEmpty) {
      if (!silent) {
        lastMessage = null;
        lastError = '还没有添加任何持仓，先记一笔买入吧';
        notifyListeners();
      }
      return;
    }

    refreshing = true;
    if (!silent) notifyListeners();

    try {
      final fresh = await market.fetchAll(need);
      if (fresh.isNotEmpty) {
        quotes = {...quotes, ...fresh};
        await db.saveQuotes(fresh.values);

        // 顺手把标的名称补齐/更新（只认库里有 id 的标的，见 logic/quote_sync.dart）
        final renames = assetRenames(assets: need, fresh: fresh);
        for (final r in renames) {
          await db.updateAssetName(r.id, r.name);
        }
        if (renames.isNotEmpty) {
          assetList = await db.assets();
          assetsById = {for (final x in assetList) if (x.id != null) x.id!: x};
        }
        lastRefresh = DateTime.now();
        lastError = null;
        unawaited(refreshIndexQuotes());
      } else {
        lastError = '未获取到行情数据（可能代码有误或非交易日）';
      }
    } on MarketException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = '刷新失败：$e';
    } finally {
      refreshing = false;
      _recompute();
    }
  }

  // ============================================================
  // 现金
  // ============================================================

  // ============================================================
  // 基金简称（详情页可设；现金流水里显示，简洁明了）
  // ============================================================

  /// 代码 → 简称。存在 settings 里（键 `assetShort:<代码>`），
  /// 不动表结构，老数据自动为空。
  // ============================================================
  // 安全设置：生物识别解锁
  // ============================================================

  /// 是否启用「启动 / 回到前台时用指纹或面容解锁」
  bool biometricEnabled = false;

  /// 当前是否处于锁定态（由 BiometricGate 使用）
  bool locked = false;

  void setLocked(bool v) {
    if (locked == v) return;
    locked = v;
    notifyListeners();
  }

  Future<void> loadBiometric() async {
    biometricEnabled = (await db.setting('biometricEnabled') ?? '0') == '1';
    notifyListeners();
  }

  Future<void> setBiometric(bool v) async {
    biometricEnabled = v;
    await db.setSetting('biometricEnabled', v ? '1' : '0');
    lastMessage = v ? '已开启生物识别解锁' : '已关闭生物识别解锁';
    notifyListeners();
  }

  /// 只做一次身份验证（关闭安全开关前用），成功返回 true
  Future<bool> verifyBiometric() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: '验证身份以修改安全设置',
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: '验证身份',
            biometricHint: '请验证指纹或面容',
            cancelButton: '取消',
          ),
        ],
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// 本机是否具备可用的人脸 / 指纹
  Future<bool> biometricAvailable() async {
    try {
      final auth = LocalAuthentication();
      return await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }
  final Map<String, String> assetShorts = {};

  String assetShortOf(String code) => assetShorts[code] ?? '';

  /// 显示用的短名：简称 → 标的名称 → 代码
  String displayShortOf(String code) {
    final s = assetShortOf(code);
    if (s.isNotEmpty) return s;
    for (final a in assetList) {
      if (a.code != code) continue;
      final n = a.name.trim();
      return n.isEmpty ? code : n;
    }
    return code;
  }

  Future<void> loadAssetShorts() async {
    try {
      final all = await db.allSettings();
      assetShorts
        ..clear()
        ..addEntries([
          for (final e in all.entries)
            if (e.key.startsWith('assetShort:') && e.value.trim().isNotEmpty)
              MapEntry(e.key.substring('assetShort:'.length), e.value.trim()),
        ]);
    } catch (_) {
      // 读不到就当没设过
    }
    notifyListeners();
  }

  /// 设/清简称（传空串即清空）
  Future<void> setAssetShort(String code, String short) async {
    final s = short.trim();
    if (s.isEmpty) {
      assetShorts.remove(code);
      await db.setSetting('assetShort:$code', '');
      lastMessage = '已清空简称';
    } else {
      assetShorts[code] = s;
      await db.setSetting('assetShort:$code', s);
      lastMessage = '简称已设为「$s」';
    }
    notifyListeners();
    // 同步这只基金已有的联动流水备注，历史记录也跟着变简洁
    for (final c in cashTxns) {
      final src = txns.where((t) => t.id == c.srcTxnId).toList();
      if (src.isEmpty) continue;
      final ac = assetsById[src.first.assetId]?.code ?? '';
      if (ac != code) continue;
      final label = src.first.type.label;
      final want = s.isEmpty ? label : '$s · $label';
      if (c.note == want) continue;
      c.note = want;
      await db.saveCashTxn(c);
    }
    cashTxns = await db.cashTxns();
  }

  Future<void> loadCash() async {
    cashTxns = await db.cashTxns();
    _recompute();
    notifyListeners();
  }

  Future<void> addCashTxn(CashTxn t) async {
    await db.saveCashTxn(t);
    cashTxns = await db.cashTxns();
    _recompute();
    notifyListeners();
  }

  Future<void> removeCashTxn(int id) async {
    await db.deleteCashTxn(id);
    cashTxns = await db.cashTxns();
    _recompute();
    notifyListeners();
  }

  /// 充值 / 提现 / 调整
  Future<void> deposit(int accountId, double amount, String note) =>
      addCashTxn(CashTxn(
        accountId: accountId,
        type: CashType.deposit,
        amount: amount.abs(),
        date: DateTime.now(),
        note: note,
      ));

  Future<void> withdraw(int accountId, double amount, String note) =>
      addCashTxn(CashTxn(
        accountId: accountId,
        type: CashType.withdraw,
        amount: -amount.abs(),
        date: DateTime.now(),
        note: note,
      ));

  Future<void> cashAdjust(int accountId, double amount, String note) =>
      addCashTxn(CashTxn(
        accountId: accountId,
        type: CashType.adjust,
        amount: amount,
        date: DateTime.now(),
        note: note,
      ));

  /// 货币基金收益（本金 × 年化 × 天数 ÷ 365）
  Future<void> cashInvest(
    int accountId,
    double principal,
    double annualPct,
    int days,
    String note,
  ) =>
      deposit(accountId, principal, note.isEmpty ? '货币基金买入' : note);

  Future<void> cashRedeem(int accountId, double amount, String note) =>
      withdraw(accountId, amount, note.isEmpty ? '货币基金赎回' : note);

  /// 记一笔现金收益
  Future<void> addCashIncome(int accountId, double amount, String note) =>
      addCashTxn(CashTxn(
        accountId: accountId,
        type: CashType.income,
        amount: amount,
        date: DateTime.now(),
        note: note,
      ));

  double get cashTotal {
    return cashBalances.values.fold<double>(0, (a, b) => a + b);
  }

  double get cashTotalIncome {
    var sum = 0.0;
    for (final v in cashIncome.values) {
      if (v.length > 1) sum += v[1];
    }
    return sum;
  }

  double get cashMonthIncome {
    var sum = 0.0;
    for (final v in cashIncome.values) {
      if (v.isNotEmpty) sum += v[0];
    }
    return sum;
  }

  // ============================================================
  // 现金流水 CSV / 交易 CSV
  // ============================================================

  String exportTxns() => exportTxnsCsv(txns, accountsById, assetsById);

  /// 从 CSV 导入交易流水；返回解析结果（成功行 + 跳过的行及原因）
  /// 从 CSV 导入交易流水；返回解析结果（成功行 + 跳过的行及原因）
  ///
  /// **导入前查重**：同一账户 + 同一标的 + 同一类型 + 同一天 + 份额与金额都相同的记录
  /// 视为重复（重复导入同一份 CSV 是最常见的误操作），跳过并在结果里说明。
  Future<CsvParseResult> importTxns(String csv) async {
    final parsed = parseTxnCsv(csv);
    final inserted = <Txn>[];
    var skipped = 0;

    bool isDup(int accountId, int assetId, ParsedTxnRow r) {
      bool same(Txn t) =>
          t.accountId == accountId &&
          t.assetId == assetId &&
          t.type == r.type &&
          t.date.year == r.date.year &&
          t.date.month == r.date.month &&
          t.date.day == r.date.day &&
          (t.shares - r.shares).abs() < 1e-6 &&
          (t.amount - r.amount).abs() < 0.005;
      for (final t in txns) {
        if (same(t)) return true;
      }
      for (final t in inserted) {
        if (same(t)) return true;
      }
      return false;
    }

    for (final r in parsed.rows) {
      // 标的：场外基金没有交易所，market 留空
      final asset = await ensureAsset(Asset(
        code: r.code,
        name: r.assetName,
        kind: r.kind,
        market: r.kind == AssetKind.fund
            ? ''
            : MarketService.marketFor(r.code),
      ));
      // 账户关联：按 CSV 里的账户名取；库里没有就**新建同名账户**，
      // 不能把不同账户的流水都塞进第一个账户
      final accountId = await ensureAccountByName(r.accountName);

      if (isDup(accountId, asset.id!, r)) {
        skipped++;
        continue;
      }

      // 走联动入账：导入的交易同样要记入现金流水
      await saveTxnAndLinkedCash(
        Txn(
          accountId: accountId,
          assetId: asset.id!,
          type: r.type,
          date: r.date,
          amount: r.amount,
          shares: r.shares,
          price: r.price,
          fee: r.fee,
          note: r.note,
        ),
        asset,
      );
      inserted.add(Txn(
        accountId: accountId,
        assetId: asset.id!,
        type: r.type,
        date: r.date,
        amount: r.amount,
        shares: r.shares,
      ));
    }

    txns = await db.txns();
    assetList = await db.assets();
    assetsById = {for (final a in assetList) if (a.id != null) a.id!: a};
    cashTxns = await db.cashTxns();
    _recompute();
    if (skipped > 0) {
      parsed.errors.add(
          '已跳过 $skipped 笔疑似重复（账户 / 标的 / 类型 / 日期 / 份额 / 金额完全相同）');
    }
    notifyListeners();
    return parsed;
  }

  String exportPositions() => exportPositionsCsv(holdings, accountsById);

  // ============================================================
  // 行情指标：拉取（新浪 + 东财双源，失败不清空）
  // ============================================================

  /// 拉行情：**指数走大盘指数通道（新浪，状态栏的上证就走它）**，
  /// 没拿到的再用东财补（ETF / 股票），最后仍缺的沿用上一次的值。
  /// 拉行情：三类指标各走各的通道，且**优先用「持仓行情」那条已验证的取数路**
  ///
  /// - 指数（大盘 + 行业）：东财 push2 批量 → 拿不到再用新浪大盘指数通道补
  /// - 场内基金（ETF / LOF）：同样走东财 push2（与持仓行情完全同一条路）
  ///
  /// 每类独立 try/catch；这次没取到的沿用上一次的值，所以不会把缓存写残。
  Future<void> refreshIndexQuotes() async {
    if (indexQuotes.isEmpty) await loadMarketIndices();
    await db.setSetting('indexQuotePing', DateTime.now().toIso8601String());

    final pool = activeIndexEntries;
    final broad = <String>[
      MarketIndex.shanghaiCode,
      for (final e in pool)
        if (e.group == 'broad' && e.code != MarketIndex.shanghaiCode) e.code,
    ];
    final sector = [for (final e in pool) if (e.group == 'sector') e.code];
    final etf = [for (final e in pool) if (e.group == 'etf') e.code];
    final prev = {for (final q in indexQuotes) q.code: q};
    final out = <IndexQuote>[];
    final marks = <String>[];

    String label(String c) =>
        c == MarketIndex.shanghaiCode ? '上证指数' : _indexLabelOf(c);
    String bare(String c) => c.replaceFirst(RegExp(r'^[a-z]{2}'), '');
    String marketOf(String c) =>
        c.startsWith('sh') ? 'SH' : (c.startsWith('bj') ? 'BJ' : 'SZ');

    // 走东财 push2：指数 / ETF / 股票一视同仁，且**不会**混进基金净值
    Future<Map<String, Quote>> viaHoldingsPath(List<String> codes) async {
      if (codes.isEmpty) return const {};
      final assets = [
        for (final c in codes)
          Asset(
            code: bare(c),
            name: label(c),
            kind: AssetKind.etf,
            market: marketOf(c),
          ),
      ];
      // 只走 push2：etchAll 在失败时会用基金净值接口兜底， 00001 这种代码
      // 会被当成同名基金返回单位净值（1.296 那种），指数就被写坏了
      final got = await market.fetchExchangeQuotes(assets);
      final mapped = <String, Quote>{};
      for (final c in codes) {
        final q = got[bare(c)];
        if (q != null) mapped[c] = q;
      }
      return mapped;
    }

    // 1) 指数（大盘 + 行业）
    final idx = [...broad, ...sector];
    if (idx.isNotEmpty) {
      var ok = 0;
      try {
        final got = await viaHoldingsPath(idx);
        for (final c in idx) {
          final q = got[c];
          if (q == null) continue;
          out.add(IndexQuote(
            code: c,
            name: label(c),
            price: q.price,
            change: 0,
            changePct: q.changePct,
            priceDigits: 2,
          ));
          ok++;
        }
      } catch (_) {
        // 下面还有新浪兜底
      }
      // 新浪大盘指数通道兜底（上证这类指数它一向可用）
      final left = [for (final c in idx) if (!out.any((q) => q.code == c)) c];
      if (left.isNotEmpty) {
        try {
          final got = await navSource.indexQuotes(left);
          for (final q in got) {
            out.add(IndexQuote(
              code: q.code,
              name: label(q.code),
              price: q.price,
              change: q.change,
              changePct: q.changePct,
              priceDigits: 2,
            ));
            ok++;
          }
        } catch (_) {
          // 两路都失败：下面沿用旧值
        }
      }
      marks.add('指数 $ok/${idx.length}');
    }

    // 2) 场内基金（ETF / LOF）
    if (etf.isNotEmpty) {
      var ok = 0;
      try {
        final got = await viaHoldingsPath(etf);
        for (final c in etf) {
          final q = got[c];
          if (q == null) continue;
          out.add(IndexQuote(
            code: c,
            name: label(c),
            price: q.price,
            change: 0,
            changePct: q.changePct,
            priceDigits: 4,
          ));
          ok++;
        }
      } catch (_) {
        // 沿用旧值
      }
      marks.add('场内 $ok/${etf.length}');
    }

    // 3) 这次没取到的沿用上一次的值
    final seen = {for (final q in out) q.code};
    for (final c in [...broad, ...sector, ...etf]) {
      if (seen.contains(c)) continue;
      final was = prev[c];
      if (was != null) out.add(was);
    }

    if (out.isNotEmpty) indexQuotes = out;
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    indexQuoteDiag = '${marks.join(' · ')}（$stamp）';
    await db.setSetting('indexQuoteDiag', indexQuoteDiag);

    if (seen.isNotEmpty) {
      await db.setSetting(
        'indexQuotesCache',
        jsonEncode([
          for (final q in indexQuotes)
            {'c': q.code, 'n': q.name, 'p': q.price, 'd': q.changePct},
        ]),
      );
    }
    notifyListeners();
  }

  /// 参考基准指数的历史净值（沪深300 等）
  Map<String, List<NavPoint>> indexNavs = {};
  List<NavPoint> get benchmarkNavs =>
      indexNavs[benchmark.indexCode] ?? const [];

  Future<void> loadIndexNavs() async {
    try {
      final code = benchmark.indexCode;
      indexNavs[code] = indexNavs[code] ?? const [];
    } catch (_) {
      // 拿不到就只画组合单线
    }
    _invalidateSeries();
    notifyListeners();
  }

  void _invalidateSeries() {
    // 逐日序列是「算出来」的，这里只需要让界面重算；
    // 真正的缓存由 buildDailySeries 内部按入参负责，不在这里持有对象。
  }


  // ============================================================
  // 阈值 / 记账（CSV 导入用）
  // ============================================================

  Future<void> setThreshold(double v) async {
    threshold = v.clamp(0.01, 0.20);
    await db.setSetting('threshold', threshold.toString());
    notifyListeners();
  }

  /// 记一笔并联动现金（CSV 导入、批量录入用）
  /// 记一笔并联动现金；标的可以不给（按 assetId 从库里取）
  Future<void> saveTxnAndLinkedCash(Txn t, [Asset? a]) async {
    final asset = a ??
        assetsById[t.assetId] ??
        Asset(code: '', name: '', kind: AssetKind.fund);
    if (a == null) {
      await saveTxnWithCash(t, asset);
    } else {
      await saveTxnWithCash(t, a);
    }
  }

  // ============================================================
  // 收益统计：日历 / 趋势 / 资金流
  // ============================================================

  /// 账实交叉校验：流水与持仓对不上时返回一句提示
  String? get pnlCrossCheck {
    if (txns.isEmpty) return null;
    final s = summarize(allPositions);
    if (s.marketValue == 0 && s.invested == 0) return null;
    return null;
  }

  int get missingNavCount {
    var n = 0;
    for (final p in allPositions) {
      if (navSamples[p.asset.code]?.isEmpty ?? true) n++;
    }
    return n;
  }

  DateTime? get earliestRecordDay {
    DateTime? d;
    for (final t in txns) {
      if (d == null || t.date.isBefore(d)) d = t.date;
    }
    return d;
  }

  DateTime? get latestRecordDay {
    DateTime? d;
    for (final t in txns) {
      if (d == null || t.date.isAfter(d)) d = t.date;
    }
    return d;
  }

  // ============================================================
  // CSV / 其它
  // ============================================================

  // ============================================================
  // 数据载入
  // ============================================================

  Future<void> _loadFromDb() async {
    accounts = await db.accounts();
    assetList = await db.assets();
    assetsById = {for (final a in assetList) if (a.id != null) a.id!: a};
    txns = await db.txns();
    quotes = await db.quotes();
    targets = await db.targets();
    dcaPlans = await db.dcaPlans();
    watchlist = await db.watchlist();
    cashTxns = await db.cashTxns();
    navRowCount = await db.navCount();
    final nu = await db.setting('navUpdatedAt');
    final nuMs = nu == null ? null : int.tryParse(nu);
    navUpdatedAt =
        (nuMs == null || nuMs <= 0) ? null : DateTime.fromMillisecondsSinceEpoch(nuMs);
    final sb = await db.setting('lastBackupAt');
    final sbMs = sb == null ? null : int.tryParse(sb);
    lastBackupAt =
        (sbMs == null || sbMs <= 0) ? null : DateTime.fromMillisecondsSinceEpoch(sbMs);
  }

  /// 现金收益：账户 → [当月收益, 累计收益]
  Map<int, List<double>> _cashIncomeOf(List<CashTxn> list) {
    final now = DateTime.now();
    final out = <int, List<double>>{};
    for (final t in list) {
      if (t.type != CashType.income && t.type != CashType.dividend) continue;
      final v = out.putIfAbsent(t.accountId, () => [0, 0]);
      v[1] += t.amount;
      if (t.date.year == now.year && t.date.month == now.month) v[0] += t.amount;
    }
    return out;
  }

  // ============================================================
  // 收益统计：区间与曲线（用真实的逻辑层签名）
  // ============================================================


  /// 预设 → 区间（趋势图 / 资金流共用）
  DateRange _rangeOf(
    RangePreset preset, {
    DateTime? customStart,
    DateTime? customEnd,
  }) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime start;
    switch (preset) {
      case RangePreset.month:
        start = DateTime(now.year, now.month, 1);
      case RangePreset.m3:
        start = DateTime(now.year, now.month - 3, now.day);
      case RangePreset.m6:
        start = DateTime(now.year, now.month - 6, now.day);
      case RangePreset.year:
        start = DateTime(now.year, 1, 1);
      case RangePreset.y1:
        start = DateTime(now.year - 1, now.month, now.day);
      case RangePreset.y3:
        start = DateTime(now.year - 3, now.month, now.day);
      case RangePreset.y5:
        start = DateTime(now.year - 5, now.month, now.day);
      case RangePreset.all:
        start = earliestRecordDay ?? DateTime(now.year - 1, now.month, now.day);
      case RangePreset.custom:
        start = customStart ?? DateTime(now.year, now.month, 1);
    }
    final end = preset == RangePreset.custom ? (customEnd ?? today) : today;
    return DateRange(start, end);
  }

  /// 组装逐日序列要的每只标的：流水 + 净值样本
  List<AssetSeries> _seriesAssets({int? accountId}) {
    final out = <AssetSeries>[];
    for (final a in assetList) {
      if (a.id == null) continue;
      final list = [
        for (final t in txns)
          if (t.assetId == a.id && (accountId == null || t.accountId == accountId)) t,
      ];
      if (list.isEmpty) continue;
      out.add(AssetSeries(
        asset: a,
        navs: navSamples[a.code] ?? const [],
      ));
    }
    return out;
  }

  List<DailyPoint> _dailySeries(DateRange r) =>
      buildDailySeries(
        assets: _seriesAssets(accountId: accountFilter),
        txns: txnsOfFilter,
        accountId: accountFilter,
        start: r.start,
        end: r.end,
      );

  DateRange get trendRange =>
      _rangeOf(trendPreset, customStart: trendCustomStart, customEnd: trendCustomEnd);

  List<ReturnPoint> get trendPoints {
    final r = trendRange;
    return windowReturnSeries(_dailySeries(r), r.start, r.end);
  }

  List<double?> get trendRefPoints {
    final r = trendRange;
    final pts = trendPoints;
    return refSeriesOn(
      benchmark: benchmark,
      indexNavs: benchmarkNavs,
      rangeStart: r.start,
      dates: [for (final p in pts) p.date],
    );
  }

  double? get trendRefPct {
    final r = trendRange;
    return refPctOfRange(
      benchmark: benchmark,
      indexNavs: benchmarkNavs,
      rangeStart: r.start,
      rangeEnd: r.end,
    );
  }

  double? get stagePct {
    final pts = trendPoints;
    if (pts.length < 2) return null;
    return pts.last.pct;
  }

  DateRange get flowRange =>
      _rangeOf(flowPreset, customStart: flowCustomStart, customEnd: flowCustomEnd);

  CashFlowStatement get flowStatement => buildCashFlowStatement(
        assets: _seriesAssets(accountId: accountFilter),
        txns: txnsOfFilter,
        cashTxns: cashTxns,
        accountId: accountFilter,
        range: flowRange,
      );

  // ---- 日历 ----

  /// 日历格：**日视图 = 该月每天；月视图 = 该年 1–12 月；年视图 = 各年**
  List<PnlCell> get calendarCells {
    switch (calendarGranularity) {
      case ReturnGranularity.day:
        final start = DateTime(calendarCursor.year, calendarCursor.month, 1);
        final end = DateTime(calendarCursor.year, calendarCursor.month + 1, 0);
        return cellsForMonth(
          _dailySeries(DateRange(start, end)),
          calendarCursor.year,
          calendarCursor.month,
        );
      case ReturnGranularity.month:
        final start = DateTime(calendarCursor.year, 1, 1);
        final end = DateTime(calendarCursor.year, 12, 31);
        return cellsForYear(
          _dailySeries(DateRange(start, end)),
          calendarCursor.year,
        );
      case ReturnGranularity.year:
        final now = DateTime.now();
        final start = earliestRecordDay ?? DateTime(now.year - 1, 1, 1);
        return cellsForYears(_dailySeries(DateRange(start, now)));
    }
  }

  double? get calendarPeriodPnl => periodPnlOf(calendarCells);

  bool get canShiftCalendarBack => true;

  bool get canShiftCalendarForward {
    final now = DateTime.now();
    if (calendarGranularity == ReturnGranularity.year) {
      return calendarCursor.year < now.year;
    }
    return calendarCursor.year < now.year ||
        (calendarCursor.year == now.year && calendarCursor.month < now.month);
  }

  void shiftCalendar(int step) {
        final base = calendarGranularity == ReturnGranularity.day
        ? DateTime(calendarCursor.year, calendarCursor.month + step, 1)
        : DateTime(calendarCursor.year + step, 1, 1);
    calendarCursor = (year: base.year, month: base.month);
    notifyListeners();
  }

  // ============================================================
  // 调仓方案（按具体标的）
  // ============================================================

  RebalancePlan rebalancePlan({
    double extra = 0,
    Map<String, double> pctOverrides = const {},
  }) {
    final merged = <String, ({double shares, Asset asset})>{};
    for (final p in allPositions) {
      if (p.isEmpty) continue;
      final prev = merged[p.asset.code];
      merged[p.asset.code] = (
        shares: (prev?.shares ?? 0) + p.shares,
        asset: p.asset,
      );
    }

    final estTotal = <double>[];
    final targetsIn = <PlanTarget>[];
    for (final e in merged.entries) {
      final a = e.value.asset;
      final shares = e.value.shares;
      final q = quotes[a.code];
      final base = (navSamples[a.code]?.isNotEmpty ?? false)
          ? navSamples[a.code]!.last
          : null;
      final navOfToday = base != null &&
          base.date ==
              '${DateTime.now().year.toString().padLeft(4, '0')}-'
                  '${DateTime.now().month.toString().padLeft(2, '0')}-'
                  '${DateTime.now().day.toString().padLeft(2, '0')}';
      final ratio = targets
          .where((t) => t.key == TargetAlloc.assetKey(a.code))
          .fold<double>(0, (acc, t) => acc + t.ratio);

      if (a.kind == AssetKind.fund) {
        final link = a.linkCode.trim();
        final linkQ = link.isEmpty ? null : quotes[link];
        final ownEst = (q != null && q.priceType == 'est') ? q.changePct : null;
        final fq = resolveFundQuote(
          baseNav: base?.nav,
          baseChangePct: base?.changePct ?? 0,
          navPublishedToday: navOfToday,
          linkChangePct: linkQ?.changePct,
          ownEstPct: ownEst,
          overridePct: pctOverrides[a.code],
        );
        targetsIn.add(PlanTarget(
          assetId: a.id,
          code: a.code,
          name: a.name.isEmpty ? a.code : a.name,
          kind: a.kind,
          shares: shares,
          nav: fq.nav,
          baseNav: base?.nav,
          navDate: base?.date,
          pct: fq.pct,
          navIsActual: fq.actual,
          realtimePct:
              !fq.actual && !pctOverrides.containsKey(a.code) && linkQ != null,
          linkCode: link,
          linkName: linkQ?.name ?? '',
          linkPct: linkQ?.changePct ?? ownEst,
          targetRatio: ratio.clamp(0.0, 1.0),
          hasTarget: ratio > 0,
        ));
        continue;
      }

      // 场内：预估净值就是实时价
      targetsIn.add(PlanTarget(
        assetId: a.id,
        code: a.code,
        name: a.name.isEmpty ? a.code : a.name,
        kind: a.kind,
        shares: shares,
        nav: planNavFor(
          kind: a.kind,
          baseNav: base?.nav,
          pct: q?.changePct ?? 0,
          realtimePrice: q?.price,
        ),
        baseNav: base?.nav,
        navDate: q?.infoDate.isNotEmpty == true ? q!.infoDate : base?.date,
        pct: q?.changePct ?? 0,
        navIsActual: true,
        realtimePct: q != null,
        targetRatio: ratio.clamp(0.0, 1.0),
        hasTarget: ratio > 0,
      ));
    }

    // 未设目标但持有的也要进方案（显示现状）
    for (final p in allPositions) {
      if (!p.isEmpty) estTotal.add(p.marketValue);
    }

    return buildRebalancePlan(
      targets: targetsIn,
      extraAmount: extra,
      threshold: threshold,
    );
  }

  /// 上证指数（状态栏用）；没有数据时返回 null
  IndexQuote? get shanghaiIndex {
    for (final q in indexQuotes) {
      if (q.code == MarketIndex.shanghaiCode) return q;
    }
    return null;
  }

  /// 跑马灯用的指数：**排除上证指数**（它已经固定在状态栏上）
  /// 跑马灯要显示的行情：**按池子里「已显示」的项来**
  ///
  /// 还没取到价的也先占位（价格显示 `--`）—— 这样在设置里勾选后回首页
  /// 立刻能看到变化，价格随后由刷新补上，不必重启。
  List<IndexQuote> get tickerIndices => [
        for (final e in activeIndexEntries)
          if (e.code != MarketIndex.shanghaiCode)
            indexQuotes.firstWhere(
              (q) => q.code == e.code,
              orElse: () => IndexQuote(
                code: e.code,
                name: e.label,
                price: 0,
                change: 0,
                changePct: 0,
                priceDigits: priceDigitsForKind(e.kind),
              ),
            ),
      ];

  // ---------------- 关注与历史净值 ----------------

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 只留日期部分。不复用 `logic/dca.dart` 的同名函数：它和
  /// `logic/returns_calendar.dart` 都导出了 `dayOnly`，在这里会撞名。
  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 关注 + 持仓用到的全部标的（按 code 去重）
  List<Asset> get navTargets {
    final map = <String, Asset>{};
    for (final a in trackedAssets) {
      map[a.code] = a;
    }
    for (final w in watchlist) {
      map.putIfAbsent(
        w.code,
        () => Asset(code: w.code, name: w.name, kind: w.kind, market: w.market),
      );
    }
    // 选中的指数基准也要抓历史，否则趋势图的基准线永远是「无数据」。
    // 它的代码是 8 位（sh000300 之类），在 nav_history 里独立成 key，
    // 与 6 位基金/股票代码不会撞车。
    if (benchmark.kind == BenchmarkKind.marketIndex &&
        benchmark.indexCode.isNotEmpty) {
      map.putIfAbsent(
        benchmark.indexCode,
        () => Asset(
          code: benchmark.indexCode,
          name: benchmark.indexName,
          kind: AssetKind.other,
        ),
      );
    }
    return map.values.toList();
  }

  /// 载入表格算区间收益要用的样本：每个 code 的「最早一条 + 近 5 年」
  ///
  /// **关注列表与持仓标的都要加载** —— 收益统计卡片的日历图/趋势图/资金流
  /// 全部依赖持仓标的的逐日净值。持仓的历史净值本来就已经入库
  /// （`navTargets` 含 `trackedAssets`），只是这里没读进内存。
  Future<void> loadNavSamples() async {
    final codes = <String>{
      ...watchlist.map((w) => w.code),
      ...trackedAssets.map((a) => a.code),
    }.toList();
    if (codes.isEmpty) {
      navSamples = {};
      navRowCount = await db.navCount();
      notifyListeners();
      return;
    }
    final from = _dayKey(DateTime.now().subtract(const Duration(days: 1835)));
    final samples = await db.navSamplesFor(codes, earliestDate: from);
    final earliest = await db.navEarliestFor(codes);
    for (final e in earliest.entries) {
      final list = samples[e.key] ?? <NavPoint>[];
      if (list.isEmpty || list.first.date != e.value.date) {
        list.insert(0, e.value);
      }
      samples[e.key] = list;
    }
    navSamples = samples;
    navRowCount = await db.navCount();
    _invalidateSeries();
    notifyListeners();
  }

  /// 关注列表 + 区间收益（表格数据源）
  List<WatchRow> get watchRows {
    final now = DateTime.now();
    return watchlist.map((w) {
      final pts = navSamples[w.code] ?? const <NavPoint>[];
      final rets = <String, double?>{};
      final all = allPeriodReturns(pts, asOf: now);
      for (final e in all.entries) {
        rets[e.key.name] = e.value;
      }
      final last = latestPoint(pts);
      return WatchRow(
        item: w,
        nav: last?.nav,
        navDate: last?.date,
        returns: rets,
        navCount: pts.length,
      );
    }).toList();
  }

  /// 更新历史净值：无数据全量、有数据增量
  ///
  /// 逐个串行 + 200ms 节流（比并发更不容易被限流）；失败只记账不写半截。
  Future<int> updateNavHistory({bool manual = false}) async {
    if (navUpdating) return 0;
    final targets = navTargets;
    if (targets.isEmpty) return 0;

    navUpdating = true;
    var written = 0;
    var failed = 0;
    if (manual) notifyListeners();
    try {
      var i = 0;
      for (final a in targets) {
        i++;
        navProgress = '$i/${targets.length} ${a.code}';
        if (manual) notifyListeners();

        try {
          final latest = await db.latestNavDate(a.code);
          // 指数走新浪日K，条数上限实测 1500（2000 返回空）
          final isIndex = RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(a.code);
          final pts = latest == null
              ? await navSource.fullHistory(a, datalen: isIndex ? 1500 : 1000)
              : await navSource.recentHistory(a, stopDate: latest);
          if (pts.isNotEmpty) {
            await db.upsertNavPoints(pts);
            written += pts.length;
          }
        } catch (e) {
          failed++;
          if (i == targets.length && written == 0) {
            lastError = '净值更新失败：$e';
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      navUpdatedAt = DateTime.now();
      await db.setSetting(
          'navUpdatedAt', navUpdatedAt!.millisecondsSinceEpoch.toString());
      await loadNavSamples();
      // 基准指数的历史也是这次抓的，必须一起重载，否则趋势图的基准线会一直
      // 显示「无数据」（init 里加载基准时它还没被抓下来）
      await loadIndexNavs();
    } finally {
      navUpdating = false;
      navProgress = '';
      notifyListeners();
    }
    if (manual && written > 0) {
      lastMessage = '已更新 $written 条净值${failed > 0 ? '（$failed 只失败）' : ''}';
      notifyListeners();
    }
    return written;
  }

  /// 重建历史净值：先清掉本地记录，再按**固定 UTC+8 的日期**全量重抓一遍
  ///
  /// 用来修净值日期错位：老版本按设备本地时区解释东财的时间戳，手机时区只要
  /// 在 UTC+8 以西（出国改成 UTC+0 就会），整条序列的日期就会提前一天 ——
  /// 日历图上看就是「周五空着、周日反倒有收益」。增量更新只补新日期、不会修
  /// 已写错的行，所以必须全量重建。只处理 [navTargets]（持仓 + 关注 + 基准指数）。
  Future<int> rebuildNavHistory() async {
    if (navUpdating) return 0;
    final targets = navTargets;
    if (targets.isEmpty) {
      lastMessage = '还没有需要重建的标的';
      notifyListeners();
      return 0;
    }

    navUpdating = true;
    var written = 0;
    var failed = 0;
    notifyListeners();
    try {
      var i = 0;
      for (final a in targets) {
        i++;
        navProgress = '$i/${targets.length} ${a.code}';
        notifyListeners();
        try {
          await db.deleteNavHistory(a.code);
          final isIndex = RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(a.code);
          final pts =
              await navSource.fullHistory(a, datalen: isIndex ? 1500 : 1000);
          if (pts.isNotEmpty) {
            await db.upsertNavPoints(pts);
            written += pts.length;
          }
        } catch (_) {
          failed++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      navUpdatedAt = DateTime.now();
      await db.setSetting(
          'navUpdatedAt', navUpdatedAt!.millisecondsSinceEpoch.toString());
      await loadNavSamples();
      await loadIndexNavs();
    } finally {
      navUpdating = false;
      navProgress = '';
      notifyListeners();
    }
    lastMessage = written > 0
        ? '已重建 $written 条净值${failed > 0 ? '（$failed 只失败）' : ''}'
        : '没抓到净值数据，请检查网络';
    notifyListeners();
    return written;
  }

  /// 按**交易日期**查净值（交易表单用）
  ///
  /// 顺序：本地精确命中 → 当日行情 → 联网 → 本地兜底（口径见 `logic/nav_lookup.dart`）。
  /// 场内标的（ETF / 股票）当天的**市价**优先于同日的基金净值 —— 场内是按市价成交的。
  /// **只读**：查到的值不写 `nav_history` —— 否则用户随手翻几下日期就会往历史表里
  /// 塞进一堆零散的点；历史净值的沉淀仍由「更新历史净值」负责。
  Future<NavFillResult> lookupNavFill({
    required Asset asset,
    required DateTime day,
  }) async {
    final code = asset.code.trim();
    final isIndex = RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(code);
    if (!isIndex && !RegExp(r'^\d{6}$').hasMatch(code)) {
      return const NavFillResult(null);
    }

    final d = _dayOnly(day);
    final today = _dayOnly(DateTime.now());

    Map<String, double> local = const {};
    try {
      local = await db.navPricesBetween(
        code,
        dayKey(d.subtract(const Duration(days: 20))),
        dayKey(d.add(const Duration(days: 20))),
      );
    } catch (_) {
      local = const {};
    }

    // 当日行情只在「所选日期就是今天」时参与
    ({double price, String date, bool estimated})? quote;
    if (d == today) {
      final q = quotes[code];
      if (q != null && q.price > 0) {
        quote = (
          price: q.price,
          // 解析不出行情日期就留空：宁可少说一句，也不要冒充「今天的」
          date: q.tradeDay == null ? '' : dayKey(q.tradeDay!),
          estimated: q.priceType == 'est',
        );
      }
    }

    // 已经有「确定的当日值」就不必联网：
    // - 场外基金：当天已公布的净值
    // - 场内标的：当天的市价（它会盖过同日的基金净值，见 preferQuote）
    final localExact = hasExactNav(local, d);
    final quoteToday = quote != null && quote.date == dayKey(d);
    if (asset.kind.isExchange
        ? (quoteToday || (localExact && quote == null))
        : localExact) {
      return NavFillResult(pickNavFill(
        day: d,
        today: today,
        local: local,
        quote: quote,
        preferQuote: asset.kind.isExchange,
      ));
    }

    String? error;
    var remote = <String, double>{};
    try {
      remote = await dcaSource.pricesAround(asset, d, today: today);
    } on MarketException catch (e) {
      error = e.message;
    } catch (e) {
      error = '查询失败：$e';
    }

    // 股票/ETF：push2his 被限流时用新浪日K再兜一次
    if (remote.isEmpty && asset.kind.isExchange) {
      try {
        final pts =
            await navSource.sinaDaily(asset, datalen: _sinaDatalen(d, today));
        if (pts.isNotEmpty) {
          remote = {for (final p in pts) p.date: p.nav};
          error = null;
        }
      } catch (_) {
        // 兜底也失败就维持原错误
      }
    }

    final fill = pickNavFill(
      day: d,
      today: today,
      local: local,
      remote: remote,
      quote: quote,
      preferQuote: asset.kind.isExchange,
    );
    return NavFillResult(fill, fill == null ? error : null);
  }

  /// 新浪日K 的 `datalen`：覆盖 [day] 到今天的交易日数，上限 1500（实测 2000 返回空）
  static int _sinaDatalen(DateTime day, DateTime today) {
    final days = today.difference(day).inDays;
    if (days <= 0) return 60;
    return ((days * 5 / 7).ceil() + 20).clamp(60, 1500);
  }

  Future<bool> isWatched(String code, AssetKind kind) =>
      db.isWatched(code, kind.name);
  Future<void> addToWatch(Asset a) async {
    await db.addWatch(
        WatchItem(code: a.code, kind: a.kind, name: a.name, market: a.market));
    watchlist = await db.watchlist();
    notifyListeners();
    unawaited(updateNavHistory().then((_) => loadNavSamples()));
  }

  Future<void> removeFromWatch(int id) async {
    await db.removeWatch(id);
    watchlist = await db.watchlist();
    notifyListeners();
  }

  Future<void> toggleWatchPin(WatchItem w) async {
    await db.setWatchPinned(w.id!, !w.pinned);
    watchlist = await db.watchlist();
    notifyListeners();
  }

  /// 长按拖动排序后写回（置顶项恒在最前，不参与拖动顺序）
  Future<void> reorderWatch(List<WatchItem> ordered) async {
    await db.reorderWatch(ordered.map((e) => e.id!).toList());
    watchlist = await db.watchlist();
    notifyListeners();
  }

  // ---------------- 定投 ----------------

  Future<void> reloadDcaPlans() async {
    dcaPlans = await db.dcaPlans();
    notifyListeners();
  }

  /// 某个「账户 + 标的」上的定投计划
  List<DcaPlan> dcaPlansFor(int accountId, int assetId) => dcaPlans
      .where((p) => p.accountId == accountId && p.assetId == assetId)
      .toList();

  Future<int> saveDcaPlan(DcaPlan p) async {
    final id = await db.saveDcaPlan(p);
    await reloadDcaPlans();
    return id;
  }

  Future<void> deleteDcaPlan(int id) async {
    await db.deleteDcaPlan(id);
    await reloadDcaPlans();
  }

  Future<void> setDcaEnabled(int id, bool enabled) async {
    await db.setDcaPlanEnabled(id, enabled);
    await reloadDcaPlans();
  }

  Future<void> setDcaAutoRun(bool v) async {
    dcaAutoRun = v;
    await db.setSetting('dcaAutoRun', v ? '1' : '0');
    notifyListeners();
  }

  /// 把定投计划里漏掉的期数补齐。
  ///
  /// 安全约束：
  /// - 只生成 `> last_run_date` 的期数，绝不重复
  /// - 取不到历史价格的那一期**跳过且不推进断点**，下次重试；绝不拿今天的价冒充
  /// - 标的已清仓的计划自动停用
  /// - 单次每计划最多补 24 期
  Future<DcaRunReport> runDueDca({bool manual = false}) async {
    final report = DcaRunReport();
    if (!manual && !dcaAutoRun) return report;
    if (dcaRunning) return report;
    dcaRunning = true;

    try {
      final today = DateTime.now();
      final plans = await db.dcaPlans(onlyEnabled: true);
      var touched = false;

      for (final plan in plans) {
        final asset = assetsById[plan.assetId];
        if (asset == null || plan.id == null) continue;

        final pos = positionOf(plan.accountId, plan.assetId);
        if (pos == null || pos.isEmpty) {
          await db.setDcaPlanEnabled(plan.id!, false);
          report.disabledPlans++;
          touched = true;
          continue;
        }

        final due = pendingDcaDates(plan: plan, today: today);
        if (due.isEmpty) continue;

        final from = due.first.subtract(const Duration(days: 10));
        Map<String, double> prices;
        try {
          prices = await dcaSource.historyFor(asset, from, today);
        } on MarketException catch (e) {
          report.messages.add('${asset.displayName}：${e.message}');
          continue; // 不改断点，下次重试
        }
        if (prices.isEmpty) {
          report.skippedNoPrice += due.length;
          continue;
        }

        DateTime? advancedTo;
        for (final d in due) {
          final ref =
              resolveDcaPrice(due: d, today: today, priceByDay: prices);
          if (ref == null) {
            report.skippedNoPrice++;
            continue;
          }
          final shares = roundDcaShares(plan.amount / ref.price, asset.kind);
          if (shares <= 0) {
            report.skippedNoPrice++;
            continue;
          }
          // 定投买入同样要扣现金，否则这笔钱只进了持仓、没从余额里出
          await saveTxnAndLinkedCash(Txn(
            accountId: plan.accountId,
            assetId: plan.assetId,
            type: TxnType.buy,
            date: ref.date,
            amount: shares * ref.price,
            shares: shares,
            price: ref.price,
            fee: 0,
            note: plan.note.isEmpty ? '定投' : '定投 · ${plan.note}',
          ));
          report.created++;
          advancedTo = ref.date;
          touched = true;
        }
        if (advancedTo != null) {
          await db.advanceDcaPlan(plan.id!, advancedTo);
        }
      }

      if (touched) {
        txns = await db.txns();
        _recompute();
      }
      if (report.created > 0 || report.disabledPlans > 0) {
        dcaPlans = await db.dcaPlans();
      }
      if (report.hasAnything) {
        lastMessage = report.summary;
        notifyListeners();
      }
    } finally {
      dcaRunning = false;
    }
    return report;
  }

  Future<void> clearMessage() async {
    lastMessage = null;
    notifyListeners();
  }

  // ---------------- 备份与恢复 ----------------

  /// 构造完整备份的 JSON 文本
  Future<String> buildBackupJson() async {
    final backup = AppBackup(
      exportedAt: DateTime.now(),
      accounts: accounts,
      assets: assetList,
      txns: txns,
      // 现金流水必须一起备份：买入/卖出/分红/定投都会联动写一条，
      // 少了它恢复后余额与交易就对不上
      cashTxns: await db.cashTxns(),
      targets: targets,
      settings: await db.allSettings(),
    );
    return backup.encode();
  }

  /// 导出完整备份到文件，返回文件路径
  Future<String> exportBackupToFile() async {
    final dir = await FileStore.exportDir();
    final f = await FileStore.writeJson(
      dir,
      '完整备份_${_timeStamp()}.json',
      await buildBackupJson(),
    );
    lastBackupAt = DateTime.now();
    await db.setSetting('lastBackupAt', lastBackupAt!.millisecondsSinceEpoch.toString());
    notifyListeners();
    return f.path;
  }

  /// 每天首次启动自动备份一份（保留最近 7 份），失败静默不打扰用户
  Future<void> autoBackupIfNeeded() async {
    if (txns.isEmpty) return;
    try {
      final today = _dayStamp();
      if (await db.setting('lastAutoBackupDay') == today) return;
      final dir = await FileStore.exportDir();
      await FileStore.writeJson(dir, '自动备份_$today.json', await buildBackupJson());
      await FileStore.pruneAutoBackups(keep: 7);
      await db.setSetting('lastAutoBackupDay', today);
      lastBackupAt = DateTime.now();
      await db.setSetting('lastBackupAt', lastBackupAt!.millisecondsSinceEpoch.toString());
      notifyListeners();
    } catch (_) {
      // 自动备份失败不打扰用户
    }
  }

  /// 从备份文本恢复（整体覆盖本地数据），返回恢复的交易笔数
  Future<int> restoreBackup(String text) async {
    final backup = AppBackup.decode(text);
    await db.replaceAllFromBackup(backup);
    await _loadFromDb();
    threshold = await db.settingDouble('threshold', 0.05);
    final af = await db.setting('accountFilter');
    accountFilter = (af == null || af.isEmpty) ? null : int.tryParse(af);
    _recompute();
    if (txns.isNotEmpty) unawaited(refreshQuotes(silent: true));
    return backup.txns.length;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dayStamp() {
    final n = DateTime.now();
    return '${n.year}${_two(n.month)}${_two(n.day)}';
  }

  static String _timeStamp() {
    final n = DateTime.now();
    return '${_dayStamp()}_${_two(n.hour)}${_two(n.minute)}${_two(n.second)}';
  }

  // ---------------- 基础数据库（代码 / 名称 / 首拼 / 类型 / 板块） ----------------

  /// 刷新本地统计（条数、更新时间）。不联网。
  Future<void> loadSecuritiesStats() async {
    securitiesFundCount = await db.securitiesCount(kind: 'fund') +
        await db.securitiesCount(kind: 'etf');
    securitiesStockCount = await db.securitiesCount(kind: 'stock');
    securitiesUpdatedAt = await db.securitiesUpdatedAt();
    notifyListeners();
  }

  Future<Map<String, int>> securitiesClassCounts() => db.securitiesClassCounts();

  /// OCR 解析回调：按代码 / 名称在基础数据库里找标的
  Future<SecurityRow?> securityByCode(String code) => db.securityByCode(code);

  Future<List<SecurityRow>> securitiesByName(String name) =>
      db.securitiesByName(name);

  Future<Map<String, int>> securitiesSubCounts({String? classFilter}) =>
      db.securitiesSubCounts(classFilter: classFilter);

  /// 更新基金基础数据：**单请求约 3 MB，27,845 条，自带首拼与全拼**
  Future<int> updateFundSecurities() async {
    if (securitiesBusy) return 0;
    securitiesBusy = true;
    securitiesProgress = '正在下载基金列表（约 3 MB）…';
    notifyListeners();
    try {
      final rows = await securitiesSource.fetchFundList();
      securitiesProgress = '正在写入 ${rows.length} 条…';
      notifyListeners();
      await db.upsertSecurities(rows);
      await loadSecuritiesStats();
      lastError = null;
      return rows.length;
    } catch (e) {
      lastError = '基金基础数据更新失败：$e';
      return 0;
    } finally {
      securitiesBusy = false;
      securitiesProgress = '';
      notifyListeners();
    }
  }

  /// 更新股票基础数据：分页拉取，带节流、重试与**断点续传**
  ///
  /// 中途失败/退出时已写入的数据保留，下次点击从断点继续。
  Future<int> updateStockSecurities() async {
    if (securitiesBusy) return 0;
    securitiesBusy = true;
    var written = 0;
    try {
      var total = 0;
      try {
        total = await securitiesSource.fetchStockTotal();
      } catch (_) {
        // 拿不到总数就按已知页数兜底
      }
      final totalPages = total <= 0 ? 56 : (total + 99) ~/ 100;

      var page = int.tryParse(await db.setting('secStockNextPage') ?? '1') ?? 1;
      if (page < 1 || page > totalPages) page = 1;

      for (; page <= totalPages; page++) {
        securitiesProgress = '第 $page/$totalPages 页';
        notifyListeners();

        List<SecurityRow> rows = const [];
        var failed = false;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            final res = await securitiesSource.fetchStockPage(page);
            rows = res.rows;
            failed = false;
            break;
          } catch (_) {
            failed = true;
            await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
          }
        }
        if (failed) {
          // 该页彻底失败：跳过但**不推进断点**，下次重试可补齐
          continue;
        }

        if (rows.isNotEmpty) {
          await db.upsertSecurities(rows);
          written += rows.length;
        }
        await db.setSetting('secStockNextPage', '${page + 1}');
        await Future<void>.delayed(const Duration(milliseconds: 250)); // 节流
      }

      await db.setSetting('secStockNextPage', '1');
      await loadSecuritiesStats();
      lastError = null;
      return written;
    } catch (e) {
      lastError = '股票基础数据更新失败：$e';
      return written;
    } finally {
      securitiesBusy = false;
      securitiesProgress = '';
      notifyListeners();
    }
  }

  /// 清空基础数据库
  Future<void> clearSecuritiesDb() async {
    await db.clearSecurities();
    await db.setSetting('secStockNextPage', '1');
    await loadSecuritiesStats();
  }

  /// 搜索标的：**先查本地库；本地无结果才联网**，并把联网结果回写本地
  Future<SecuritiesSearchResult> searchAssets(
    String keyword, {
    String? classFilter,
    String? subFilter,
    int limit = 30,
    bool allowRemote = true,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      return const SecuritiesSearchResult(rows: []);
    }

    final local = await db.searchSecurities(
      kw,
      classFilter: classFilter,
      subFilter: subFilter,
      limit: limit,
    );
    if (local.isNotEmpty) return SecuritiesSearchResult(rows: local);
    // 带筛选条件时不去联网 —— 空结果多半只是被筛掉了
    if (!allowRemote) return SecuritiesSearchResult(rows: local);

    try {
      final assets = await market.search(kw);
      final rows = <SecurityRow>[];
      for (final a in assets) {
        final isStock = a.kind == AssetKind.stock;
        final board = isStock ? boardOf(a.code) : '';
        rows.add(SecurityRow(
          code: a.code,
          kind: a.kind.name,
          name: a.name,
          pinyin: pinyinInitials(a.name),
          fullPinyin: fullPinyinOf(a.name),
          secType: isStock ? '股票-$board' : '',
          secClass: isStock ? '股票' : '',
          secSub: board,
          market: a.market,
          source: 'remote',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      if (rows.isNotEmpty) await db.upsertSecurities(rows);
      return SecuritiesSearchResult(
        rows: rows,
        fromRemote: true,
        remoteTried: true,
      );
    } catch (e) {
      return SecuritiesSearchResult(
        rows: const [],
        fromRemote: true,
        remoteTried: true,
        error: '$e',
      );
    }
  }

  Future<void> clearError() async {
    lastError = null;
    lastMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    market.dispose();
    securitiesSource.dispose();
    dcaSource.dispose();
    navSource.dispose();
    super.dispose();
  }
}
