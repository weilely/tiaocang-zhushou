/// 宏观估值（股债利差）取数
///
/// 口径：`股债利差 = 沪深300盈利收益率(1/PE) − 10年期国债收益率`，
/// 数值越大说明股票相对债券越便宜。
///
/// 数据源（2026-09 逐个实测过，都是公开只读接口）：
/// - **PE 走中证指数官网**（权威、日频、历史长）：`index-perf` 响应里的
///   `peg` 字段就是市盈率 —— 实测 13.34/13.42，与蛋卷的 13.38 吻合。
/// - **10年期国债走东财 push2** `secid=171.CN10Y`，**f43 ÷ 10000 = 收益率%**。
///   缩放校验过：2年 1.2587 < 10年 1.6932 < 30年 2.1834，收益率曲线次序正常。
/// - 蛋卷只用来取**长窗口 PE 分位**（弥补本地历史太短的短板），失败不影响主流程。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次取到的宏观估值
class MacroPoint {
  /// 日期 `yyyy-MM-dd`
  final String date;

  /// 沪深300 市盈率（中证官网官方口径）
  final double hs300Pe;

  /// 10年期国债收益率（%）
  final double cn10y;

  /// 股债利差（%）
  final double erp;

  /// 蛋卷给的**长窗口** PE 分位（0~1），取不到为 null
  final double? pePercentileLong;

  /// 上面那个长窗口分位的**窗口起点**（界面上要标出来，别让人当成长周期分位）
  final DateTime? peWindowStart;

  const MacroPoint({
    required this.date,
    required this.hs300Pe,
    required this.cn10y,
    required this.erp,
    this.pePercentileLong,
    this.peWindowStart,
  });

  /// 盈利收益率（%）= 1/PE
  double get earningsYield => hs300Pe > 0 ? 100.0 / hs300Pe : 0;
}

/// 取「今天」的宏观估值；任一关键项取不到就返回 null
Future<MacroPoint?> fetchMacroPoint({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final pe = await fetchHs300Pe(timeout: timeout);
  final bond = await fetchCn10y(timeout: timeout);
  if (pe == null || pe.value <= 0 || bond == null) return null;
  final pct = await fetchHs300PePercentile(timeout: timeout); // 拿不到不影响
  final ey = 100.0 / pe.value;
  return MacroPoint(
    date: bond.date.isNotEmpty ? bond.date : pe.date,
    hs300Pe: pe.value,
    cn10y: bond.value,
    erp: ey - bond.value,
    pePercentileLong: pct?.$1,
    peWindowStart: pct?.$2,
  );
}

/// 带日期的数值
class DatedValue {
  final String date;
  final double value;
  const DatedValue(this.date, this.value);
}

/// 沪深300 PE —— 中证指数官网
///
/// 只用它的**官方 PE**（`peg` 字段）。取最近一段区间后拿最后一条非空值，
/// 因为官网当日数据有时要收盘后才更新。
Future<DatedValue?> fetchHs300Pe({
  String indexCode = '000300',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now();
  final start = end.subtract(const Duration(days: 20));
  String ymd(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  final url = Uri.parse('https://www.csindex.com.cn/csindex-home/perf/'
      'index-perf?indexCode=$indexCode'
      '&startDate=${ymd(start)}&endDate=${ymd(end)}');
  final res = await http.get(url).timeout(timeout);
  if (res.statusCode != 200) return null;
  final body = jsonDecode(res.body);
  if (body is! Map) return null;
  final list = body['data'];
  if (list is! List) return null;
  // 从后往前找第一个有 PE 的交易日
  for (final row in list.reversed) {
    if (row is! Map) continue;
    final raw = row['peg'];
    final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (v == null || v <= 0) continue;
    final d = '${row['tradeDate'] ?? ''}';
    return DatedValue(_iso(d), v);
  }
  return null;
}

/// 10年期国债收益率（%）—— 东财 push2 `171.CN10Y`，f43÷10000
Future<DatedValue?> fetchCn10y({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final url = Uri.parse('https://push2.eastmoney.com/api/qt/stock/get'
      '?secid=171.CN10Y&fields=f43,f58,f86');
  final res = await http.get(url).timeout(timeout);
  if (res.statusCode != 200) return null;
  final body = jsonDecode(res.body);
  if (body is! Map) return null;
  final data = body['data'];
  if (data is! Map) return null;
  final raw = data['f43'];
  final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (v == null) return null;
  // f43 是整数缩放值：16932 → 1.6932%
  final yieldPct = v / 10000.0;
  // 明显不合理的值直接丢掉（国债收益率不可能到 20% 以上或为负很多）
  if (yieldPct <= 0 || yieldPct > 20) return null;
  final ts = data['f86'];
  final date = ts is num && ts > 0
      ? _iso(DateTime.fromMillisecondsSinceEpoch((ts * 1000).round())
          .toLocal()
          .toIso8601String()
          .substring(0, 10)
          .replaceAll('-', ''))
      : '';
  return DatedValue(date, yieldPct);
}

/// 沪深300 **长窗口** PE 分位（0~1）—— 蛋卷；取不到返回 null
///
/// 本地累积的历史还短，这个长窗口分位能补上"当前贵不贵"的参照。
/// 返回的第二个值是该分位的**窗口起点**（蛋卷响应里的 `begin_at`）——
/// 界面上必须把"这个分位是多久的"写出来（实测 2026-09-22 时 `begin_at`
/// = 2016-06-15，即约 10 年，正好是用户要的"10 年口径"）。
Future<(double percentile, DateTime? windowStart)?> fetchHs300PePercentile({
  String symbol = 'SH000300',
  Duration timeout = const Duration(seconds: 12),
}) async {
  try {
    final url = Uri.parse(
        'https://danjuanfunds.com/djapi/index_eva/detail/$symbol');
    final res = await http.get(url).timeout(timeout);
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is! Map) return null;
    final data = body['data'];
    if (data is! Map) return null;
    final raw = data['pe_percentile'];
    final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (v == null || v < 0 || v > 1) return null;
    final begin = data['begin_at'];
    final ms = begin is num ? begin.toInt() : int.tryParse('$begin');
    return (
      v,
      ms == null || ms <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  } catch (_) {
    return null;
  }
}

/// `20260918` / `2026-09-18` → `2026-09-18`
String _iso(String raw) {
  final s = raw.trim();
  if (s.length == 8 && !s.contains('-')) {
    return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}';
  }
  final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m != null) return m.group(0)!;
  return s;
}

/// 历史分位：返回该值在 [values] 里的百分位（0~1），样本不足返回 null。
///
/// [minSamples] 用来避免"刚装上就报个分位"这种没意义的数字。
double? percentileOf(List<double> values, double value, {int minSamples = 20}) {
  if (values.length < minSamples) return null;
  final below = values.where((v) => v <= value).length;
  return below / values.length;
}

/// 历史回填用的一点（PE 与国债按日期对齐后）
class MacroBackfillPoint {
  final String date;
  final double hs300Pe;
  final double cn10y;
  const MacroBackfillPoint(this.date, this.hs300Pe, this.cn10y);
  double get erp => (hs300Pe > 0 ? 100.0 / hs300Pe : 0) - cn10y;
}

/// 回填历史：把「沪深300 PE 历史」与「10年期国债收益率历史」按日期对齐。
///
/// 为什么要回填：股债利差的价值全在"历史分位"上，不回填的话新装用户要等
/// 20 天才有分位。**用户 2026-09-22 要的是"10 年口径"**，所以两个源都换成了
/// 能覆盖 10 年的：
/// - 国债：东财数据中心「中美国债收益率」（`EMM00166466`＝中国10年期，2002 起）
///   —— 原来用的 `push2his 171.CN10Y` **硬性只有 2023-05-08 起**，撑不起 10 年；
/// - PE：中证指数官网 `index-perf` 的 `peg`（日频，2015 起）
///   —— 原来用的蛋卷 `pe_history` 是**周频**且 2016-09 起。
///
/// 两个源任意一个失败就返回空 —— 回填失败不该影响主流程（当天那一点仍会入库）。
Future<List<MacroBackfillPoint>> fetchMacroBackfill({
  int years = 10,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final bond = await _fetchCn10yHistory(years: years, timeout: timeout);
    if (bond.isEmpty) return const [];
    final pe = await _fetchHs300PeHistory(years: years, timeout: timeout);
    if (pe.isEmpty) return const [];
    return alignMacroSeries(pe: pe, bond: bond);
  } catch (_) {
    return const [];
  }
}

/// 把「PE 序列」与「国债序列」按日期对齐：PE 的每一天取**该日或之前最近**的国债值。
///
/// 抽成纯函数是为了能单测（对齐规则错一天，分位就整体偏，肉眼看不出来）。
/// 输入不要求有序；输出按日期升序，且**丢掉任一腿缺失/非正**的点。
List<MacroBackfillPoint> alignMacroSeries({
  required Map<String, double> pe,
  required Map<String, double> bond,
}) {
  final bondDates = bond.keys.toList()..sort();
  final out = <MacroBackfillPoint>[];
  var bi = -1; // 当前已扫描到的"最后一个 ≤ 当前日期"的国债下标
  for (final d in (pe.keys.toList()..sort())) {
    while (bi + 1 < bondDates.length && bondDates[bi + 1].compareTo(d) <= 0) {
      bi++;
    }
    if (bi < 0) continue; // 这天还没有国债数据
    final peV = pe[d]!;
    final y = bond[bondDates[bi]]!;
    if (peV <= 0 || y <= 0) continue;
    out.add(MacroBackfillPoint(d, peV, y));
  }
  return out;
}

/// 10年期国债收益率历史（日频）—— **东财数据中心「中美国债收益率」**（长历史）
///
/// 为什么换源：`push2his` 的 `171.CN10Y` K 线**硬性从 2023-05-08 才有**（实测
/// `beg=20050101` 首条就是它），算不了 10 年分位。东财数据中心是同一个标的、
/// 同一家厂商：`EMM00166466` = 中国国债收益率10年，实测可回溯到 2002 年。
/// **两源对数**：2026-09-22 数据中心给 1.6791，中债官网（中国债券信息网）当天
/// 也是 1.6791 —— 独立来源互验通过。
/// 失败/空则回落到原来的 `push2his`。
Future<Map<String, double>> _fetchCn10yHistory({
  int years = 10,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final out = <String, double>{};
  try {
    // 数据中心页面自带的公开 token（`data.eastmoney.com/cjsj/zmgzsyl.html`）
    const token = '894050c76af8597a853f5b408b759f5d';
    final since =
        DateTime.now().subtract(Duration(days: 365 * years + 40));
    for (var page = 1; page <= 8; page++) {
      final url = Uri.parse('https://datacenter.eastmoney.com/api/data/get'
          '?type=RPTA_WEB_TREASURYYIELD&sty=ALL&st=SOLAR_DATE&sr=-1'
          '&token=$token&ps=500&p=$page&pageNo=$page&pageNum=$page');
      final res = await http.get(url).timeout(timeout);
      if (res.statusCode != 200) break;
      final body = jsonDecode(res.body);
      if (body is! Map) break;
      final result = body['result'];
      if (result is! Map) break;
      final list = result['data'];
      if (list is! List || list.isEmpty) break;

      var oldest = '';
      for (final e in list) {
        if (e is! Map) continue;
        final d = _iso('${e['SOLAR_DATE']}'.split(' ').first);
        if (d.length != 10) continue;
        final raw = e['EMM00166466'];
        final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
        if (v == null || v <= 0 || v > 20) continue;
        out[d] = v;
        if (oldest.isEmpty || d.compareTo(oldest) < 0) oldest = d;
      }
      if (oldest.isNotEmpty && DateTime.parse(oldest).isBefore(since)) break;
      final pages = result['pages'];
      if (pages is num && page >= pages) break;
    }
  } catch (_) {
    // 掉到下面的旧通道
  }
  if (out.isNotEmpty) return out;
  return _fetchCn10yHistoryViaKline(timeout: timeout);
}

/// 旧的国债历史通道：东财 push2his（**只有 2023-05 起**，仅作兜底）
Future<Map<String, double>> _fetchCn10yHistoryViaKline(
    {Duration timeout = const Duration(seconds: 25)}) async {
  try {
    final url =
        Uri.parse('https://push2his.eastmoney.com/api/qt/stock/kline/get'
            '?secid=171.CN10Y&klt=101&fqt=1&beg=20050101&end=20500101'
            '&fields1=f1,f2,f3&fields2=f51,f53');
    final res = await http.get(url).timeout(timeout);
    if (res.statusCode != 200) return const {};
    final body = jsonDecode(res.body);
    if (body is! Map) return const {};
    final data = body['data'];
    if (data is! Map) return const {};
    final klines = data['klines'];
    if (klines is! List) return const {};
    final out = <String, double>{};
    for (final k in klines) {
      final parts = '$k'.split(',');
      if (parts.length < 2) continue;
      final v = double.tryParse(parts[1]);
      if (v == null || v <= 0 || v > 20) continue;
      out[_iso(parts[0])] = v;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// 沪深300 PE 历史（**日频，2015 起**）—— 中证指数官网 `index-perf` 的 `peg`
///
/// 为什么换源：蛋卷 `pe_history` 是**周频**且要过它的风控（本机出口 IP 已被
/// 蛋卷 403 拉黑过）。中证官网是官方口径、日频、能到 2015，实测一次请求就有
/// 全部数据。失败则回落到蛋卷周频。
Future<Map<String, double>> _fetchHs300PeHistory({
  int years = 10,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final out = <String, double>{};
  try {
    final end = DateTime.now();
    final start = end.subtract(Duration(days: 365 * years + 40));
    final url = Uri.parse('https://www.csindex.com.cn/csindex-home/perf/'
        'index-perf?indexCode=000300'
        '&startDate=${_ymd(start)}&endDate=${_ymd(end)}');
    final res = await http.get(url).timeout(timeout);
    if (res.statusCode == 200) {
      final body = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      if (body is Map) {
        final list = body['data'];
        if (list is List) {
          for (final e in list) {
            if (e is! Map) continue;
            final d = _iso('${e['tradeDate']}');
            if (d.length != 10) continue;
            final raw = e['peg'];
            final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
            if (v == null || v <= 0) continue;
            out[d] = v;
          }
        }
      }
    }
  } catch (_) {
    // 掉到下面的蛋卷周频
  }
  if (out.isNotEmpty) return out;
  return _fetchHs300PeHistoryViaDanjuan(timeout: timeout);
}

/// 旧的 PE 历史通道：蛋卷 `pe_history`（周频，2016-09 起，仅作兜底）
Future<Map<String, double>> _fetchHs300PeHistoryViaDanjuan(
    {Duration timeout = const Duration(seconds: 25)}) async {
  try {
    final url = Uri.parse(
        'https://danjuanfunds.com/djapi/index_eva/pe_history/SH000300?day=all');
    final res = await http.get(url).timeout(timeout);
    if (res.statusCode != 200) return const {};
    final body = jsonDecode(res.body);
    if (body is! Map) return const {};
    final data = body['data'];
    if (data is! Map) return const {};
    final list = data['index_eva_pe_growths'];
    if (list is! List) return const {};
    final out = <String, double>{};
    for (final e in list) {
      if (e is! Map) continue;
      final pe = e['pe'];
      final v = pe is num ? pe.toDouble() : double.tryParse('$pe');
      final ts = e['ts'];
      if (v == null || v <= 0 || ts is! num || ts <= 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true);
      out['${d.year}-${d.month.toString().padLeft(2, '0')}'
          '-${d.day.toString().padLeft(2, '0')}'] = v;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// `2026-09-22` → `20260922`（中证官网要这种格式）
String _ymd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';
