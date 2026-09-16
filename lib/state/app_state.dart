import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  /// 上次刷新跑马灯行情的结果（设置页「行情指标」里显示，用来定位取数问题）
  String
            indexQuoteDiag = '新浪 $sinaGot 条 / 东财 $pushGot 条 / 写入 ${merged.length} 条（共 ${wanted.length} 只）';
      if (merged.isEmpty) return;

      indexQuotes = [
        for (final q in qs)
          IndexQuote(
            code: q.code,
            name: q.code == MarketIndex.shanghaiCode
                ? '上证指数'
                : _indexLabelOf(q.code),
            price: q.price,
            change: q.change,
            changePct: q.changePct,
            priceDigits: q.priceDigits,
          ),
      ];
      await db.setSetting(
        'indexQuotesCache',
        jsonEncode([
          for (final q in indexQuotes)
            {'c': q.code, 'n': q.name, 'p': q.price, 'd': q.changePct},
        ]),
      );
      notifyListeners();
    } catch (_) {
      // 保留旧值
    }
  }

  /// 上证指数（状态栏用）；没有数据时返回 null
  IndexQuote? get shanghaiIndex {
    for (final q in indexQuotes) {
      if (q.code == MarketIndex.shanghaiCode) return q;
    }
    return null;
  }

  /// 跑马灯用的指数：**排除上证指数**（它已经固定在状态栏上）
  List<IndexQuote> get tickerIndices =>
      [for (final q in indexQuotes) if (q.code != MarketIndex.shanghaiCode) q];

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
