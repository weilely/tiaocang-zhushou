import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/refresh_throttle.dart';

/// 行情刷新节流
///
/// 用户报：「首页下滑刷新太平繁了，限制一下」——下拉刷新 + 切回首页自动刷新
/// 两处叠起来会反复联网，所以给一个最小间隔。
void main() {
  final t0 = DateTime(2026, 9, 22, 12, 0, 0);

  group('refreshAllowed', () {
    test('从没刷过 → 允许', () {
      expect(refreshAllowed(null, t0), isTrue);
    });

    test('间隔内 → 不允许；到点 / 超过 → 允许', () {
      const iv = Duration(seconds: 60);
      expect(refreshAllowed(t0, t0.add(const Duration(seconds: 1)), minInterval: iv), isFalse);
      expect(refreshAllowed(t0, t0.add(const Duration(seconds: 59)), minInterval: iv), isFalse);
      expect(refreshAllowed(t0, t0.add(const Duration(seconds: 60)), minInterval: iv), isTrue);
      expect(refreshAllowed(t0, t0.add(const Duration(minutes: 5)), minInterval: iv), isTrue);
    });

    test('force 忽略节流（用户明确要重来的动作）', () {
      expect(
        refreshAllowed(t0, t0.add(const Duration(seconds: 1)),
            minInterval: const Duration(seconds: 60), force: true),
        isTrue,
      );
    });

    test('时钟回拨（上次在"未来"）不能把刷新卡死', () {
      expect(
        refreshAllowed(t0.add(const Duration(minutes: 5)), t0,
            minInterval: const Duration(seconds: 60)),
        isTrue,
      );
    });

    test('默认间隔是 60 秒', () {
      expect(kRefreshMinInterval, const Duration(seconds: 60));
      expect(refreshAllowed(t0, t0.add(const Duration(seconds: 30))), isFalse);
      expect(refreshAllowed(t0, t0.add(const Duration(seconds: 61))), isTrue);
    });
  });

  group('secondsUntilRefresh（给提示用）', () {
    test('不允许时给出剩余秒数', () {
      expect(secondsUntilRefresh(t0, t0.add(const Duration(seconds: 10))), 50);
      expect(secondsUntilRefresh(t0, t0.add(const Duration(seconds: 59))), 1);
    });

    test('允许时返回 0', () {
      expect(secondsUntilRefresh(t0, t0.add(const Duration(seconds: 60))), 0);
      expect(secondsUntilRefresh(t0, t0.add(const Duration(minutes: 3))), 0);
      expect(secondsUntilRefresh(null, t0), 0);
    });

    test('刚好到点时不会返回负数', () {
      expect(secondsUntilRefresh(t0, t0.add(const Duration(seconds: 61))), 0);
    });
  });
}
