/// 行情刷新的**节流**（纯函数，便于单测）
///
/// 背景（用户 2026-09-22）：「首页下滑刷新太平繁了，限制一下」——
/// 现状是：①下拉刷新每次都会联网；②**切回首页时还会自动刷一次**。
/// 两处叠起来，用户稍一滑动就反复发请求（行情源对频率敏感，也没必要）。
///
/// 策略：给"联网刷新"一个最小间隔；间隔内再触发就**跳过**，
/// 但**手动下拉**时给一句提示，让他知道不是没反应（自动触发则静默跳过）。
library;

/// 默认最小刷新间隔
const Duration kRefreshMinInterval = Duration(seconds: 60);

/// 现在允许刷新吗？
///
/// [last] 上次真正联网刷新的时刻（从没刷过传 null）；[force] 为 true 时忽略节流
/// （例如"更新历史净值"这类用户明确要重来的动作）。
bool refreshAllowed(
  DateTime? last,
  DateTime now, {
  Duration minInterval = kRefreshMinInterval,
  bool force = false,
}) {
  if (force) return true;
  if (last == null) return true;
  final elapsed = now.difference(last);
  // 时钟回拨（last 在未来）时也允许，免得被卡死
  if (elapsed.isNegative) return true;
  return elapsed >= minInterval;
}

/// 距离下次可刷新还有几秒（不允许时才有意义；向下取整、至少 1 秒）
int secondsUntilRefresh(
  DateTime? last,
  DateTime now, {
  Duration minInterval = kRefreshMinInterval,
}) {
  if (last == null) return 0;
  final left = minInterval - now.difference(last);
  if (left.isNegative || left == Duration.zero) return 0;
  return left.inSeconds < 1 ? 1 : left.inSeconds;
}
