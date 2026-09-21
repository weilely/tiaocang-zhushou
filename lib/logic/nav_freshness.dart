/// 「历史净值是不是落后了」的判断 —— 纯函数，便于单测
///
/// **要解决的问题**（用户 2026-09-22 报的「收益统计昨天 9-21 没有收益数据」）：
/// 收益统计 / 盈亏日历读的是 `nav_history` 表，而净值历史的更新是
/// **一天只跑一次、错过不补** —— 只要某天进程没跑到（或者那一刻净值还没公布），
/// 那一天就永远空着。实测：`nav_history` 停在 09-18，而实时行情里
/// 09-21 的已公布净值早就有了。
///
/// 所以每次刷新行情后对一下：**行情里已经有某天的「已公布净值」、
/// 而历史表里还没有（或更旧）** → 这只标的就该补。
library;

/// 实时行情里与"净值"有关的最小信息（避免依赖上层模型）
typedef QuoteNavInfo = ({String priceType, String infoDate});

/// 返回**需要补历史净值**的代码
///
/// - [historyLastDate]：各代码在 `nav_history` 里的最后日期（没有则为 null）
/// - [quotes]：各代码的实时行情；只有 `priceType == 'nav'`（已公布净值）才算数，
///   `est`（盘中估值）**不算** —— 估值不是真净值，不该写进历史
///
/// 日期都是 `yyyy-MM-dd` 字符串，字典序即时间序，所以直接比较即可。
List<String> staleNavCodes({
  required Map<String, String?> historyLastDate,
  required Map<String, QuoteNavInfo> quotes,
}) {
  final out = <String>[];
  for (final e in quotes.entries) {
    final q = e.value;
    if (q.priceType != 'nav') continue;
    final d = q.infoDate.trim();
    if (d.length < 10) continue; // 解析不出日期就别动
    final last = historyLastDate[e.key];
    if (last == null || last.length < 10 || last.compareTo(d) < 0) {
      out.add(e.key);
    }
  }
  out.sort(); // 稳定输出，便于测试与日志
  return out;
}
