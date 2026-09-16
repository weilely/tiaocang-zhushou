/// 交易表单「按交易日期查净值」的口径
///
/// 只用单位净值（基金的 `DWJZ`、股票/ETF 的收盘价），不用累计净值 ——
/// 交易的成交价就是单位净值。
///
/// 取价顺序（命中即返回）：
///
/// 1. 所选日期在本地/联网数据里**精确命中**
/// 2. 所选日期就是今天、且内存里有当日行情（基金可能是盘中估值）
/// 3. **顺延**到所选日期之后、不晚于今天的第一个有值日
/// 4. 退回所选日期之前最近的一个有值日
///
/// 顺延优先于回退：非交易日下单本来就在下一个交易日成交，用下单日之前的
/// 净值成交是错的。这与 `resolveDcaPrice`（`logic/dca.dart`）的口径一致，
/// 那里的注释已把理由写死，这里复用同一套规则，避免一个 App 里两套取价口径。
library;

import '../core/format.dart';
import 'dca.dart';

/// 一次「按日期取净值」的结果
class NavFill {
  final double nav;

  /// 净值实际所属的交易日（`yyyy-MM-dd`），可能不等于所选日期
  final String date;

  /// 是否与所选日期同一天
  final bool exact;

  /// 盘中估值（基金当日净值还没公布时的估值）
  final bool estimated;

  const NavFill({
    required this.nav,
    required this.date,
    required this.exact,
    this.estimated = false,
  });
}

/// 查询结果：拿到净值就是 [fill]，彻底查不到时 [error] 带上失败原因
///
/// 只有「联网也失败、本地兜底也没有」才算失败；有本地兜底值时不算失败，
/// 免得用户在离线状态看到一条吓人的红字，而其实净值已经填好了。
class NavFillResult {
  final NavFill? fill;
  final String? error;

  const NavFillResult(this.fill, [this.error]);
}

/// 本地数据里是否已有该日期的精确净值（AppState 据此决定要不要联网）
bool hasExactNav(Map<String, double> local, DateTime day) {
  final v = local[dayKey(day)];
  return v != null && v > 0;
}

/// 按上面的顺序挑一个净值；`local` / `remote` 的键都是 `yyyy-MM-dd`
///
/// [preferQuote] 为 true 时（场内标的：ETF / 股票），**当天**的行情优先于同日的
/// 基金净值：场内是按市价成交的，净值只是会计口径，两者会差零点几个百分点
/// （实测 510300 的净值 4.5489 vs 收盘 4.5520）。行情日期必须**正好是所选日期**
/// 才算数，否则宁可要那天的净值，也不能拿一份隔夜的行情冒充。
NavFill? pickNavFill({
  required DateTime day,
  required DateTime today,
  required Map<String, double> local,
  Map<String, double> remote = const {},
  ({double price, String date, bool estimated})? quote,
  bool preferQuote = false,
}) {
  final d = dayOnly(day);
  final t = dayOnly(today);
  final key = dayKey(d);

  // 联网取到的按日覆盖本地同一天：联网拿到的是已公布的权威值
  final all = <String, double>{...local, ...remote};

  double? take(String k) {
    final v = all[k];
    return (v != null && v > 0) ? v : null;
  }

  final quoteDay =
      (quote != null && quote.date.length >= 10) ? quote.date : null;
  final quoteExactToday =
      quote != null && quote.price > 0 && d == t && quoteDay == key;

  // 0. 场内标的当天的市价
  if (preferQuote && quoteExactToday) {
    return NavFill(
      nav: quote.price,
      date: quoteDay!,
      exact: true,
      estimated: quote.estimated,
    );
  }

  // 1. 精确命中
  final exact = take(key);
  if (exact != null) return NavFill(nav: exact, date: key, exact: true);

  // 2. 今天 + 当日行情（场外基金此时多半是盘中估值）
  if (d == t && quote != null && quote.price > 0) {
    return NavFill(
      nav: quote.price,
      date: quoteDay ?? key,
      exact: quoteDay == key,
      estimated: quote.estimated,
    );
  }

  // 3. 顺延到之后的第一个有值日（不越过今天）
  for (var x = d.add(const Duration(days: 1));
      !x.isAfter(t);
      x = x.add(const Duration(days: 1))) {
    final v = take(dayKey(x));
    if (v != null) return NavFill(nav: v, date: dayKey(x), exact: false);
  }

  // 4. 退回之前最近的一个有值日
  String? prev;
  for (final k in all.keys) {
    if (k.compareTo(key) > 0) continue;
    if (take(k) == null) continue;
    if (prev == null || k.compareTo(prev) > 0) prev = k;
  }
  if (prev != null) {
    return NavFill(nav: all[prev]!, date: prev, exact: prev == key);
  }

  return null;
}

/// 表单里那行提示的文案（逐字固定，测试按此断言）
///
/// [hasCode] 为 false 表示还没填代码、[queried] 为 false 表示还没为「当前代码 +
/// 当前日期」查过 —— 这两种都不是「查不到」，不该给用户一条红字。
String navFillHint({
  required DateTime day,
  NavFill? fill,
  bool busy = false,
  String? error,
  bool hasCode = true,
  bool queried = true,
}) {
  if (!hasCode) return '填入代码后自动按日期查净值';
  if (!queried) return '选中标的后自动按日期查净值';
  if (busy) return '正在查询 ${fmtDateCn(day)} 的净值…';
  if (fill == null) {
    return error == null
        ? '未查到 ${fmtDateCn(day)} 的净值，请手工填写'
        : '联网查询失败，可手工填写净值';
  }
  if (fill.estimated) return '${fill.date} 盘中估值 ${fmtPrice(fill.nav)}';
  if (!fill.exact) {
    return '该日无净值，取 ${fmtIsoMonthDay(fill.date)} 净值 ${fmtPrice(fill.nav)}';
  }
  return '${fill.date} 净值 ${fmtPrice(fill.nav)}';
}
