import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/logic/calendar_grid.dart';

void main() {
  group('每月天数', () {
    test('大月 31 天、小月 30 天', () {
      for (final m in [1, 3, 5, 7, 8, 10, 12]) {
        expect(daysInMonth(2026, m), 31, reason: '2026-$m 应为 31 天');
      }
      for (final m in [4, 6, 9, 11]) {
        expect(daysInMonth(2026, m), 30, reason: '2026-$m 应为 30 天');
      }
    });

    test('闰年 2 月 29 天、平年 28 天', () {
      expect(daysInMonth(2024, 2), 29);
      expect(daysInMonth(2000, 2), 29, reason: '2000 能被 400 整除，是闰年');
      expect(daysInMonth(2026, 2), 28);
      expect(daysInMonth(2100, 2), 28, reason: '2100 是整百年且不能被 400 整除');
      expect(daysInMonth(1900, 2), 28);
    });

    test('月份越界直接报错，不静默当成 31 天', () {
      expect(() => daysInMonth(2026, 0), throwsArgumentError);
      expect(() => daysInMonth(2026, 13), throwsArgumentError);
    });
  });

  group('1 号的星期偏移（周日起始）', () {
    test('已知基准', () {
      // 2026-09-01 是星期二 → 偏移 2
      expect(DateTime(2026, 9, 1).weekday, DateTime.tuesday);
      expect(firstWeekdayOffset(2026, 9), 2);

      // 2000-01-01 是星期六 → 偏移 6
      expect(DateTime(2000, 1, 1).weekday, DateTime.saturday);
      expect(firstWeekdayOffset(2000, 1), 6);

      // 2026-02-01 是星期日 → 偏移 0
      expect(DateTime(2026, 2, 1).weekday, DateTime.sunday);
      expect(firstWeekdayOffset(2026, 2), 0);
    });

    test('恒在 0..6 之间', () {
      for (var y = 2020; y <= 2030; y++) {
        for (var m = 1; m <= 12; m++) {
          final o = firstWeekdayOffset(y, m);
          expect(o, inInclusiveRange(0, 6));
        }
      }
    });
  });

  group('月网格', () {
    test('恒定 42 格（6 行 × 7 列），高度不随月份跳动', () {
      for (var y = 2024; y <= 2027; y++) {
        for (var m = 1; m <= 12; m++) {
          expect(monthGrid(y, m).length, kMonthGridCellCount);
          expect(monthGrid(y, m).length, 42);
        }
      }
    });

    test('非空格子恰好是当月天数，且 1 号落在偏移位置', () {
      for (var y = 2024; y <= 2027; y++) {
        for (var m = 1; m <= 12; m++) {
          final grid = monthGrid(y, m);
          final days = daysInMonth(y, m);
          final filled = grid.where((e) => e != null).toList();

          expect(filled.length, days, reason: '$y-$m 非空格子数');
          expect(grid[firstWeekdayOffset(y, m)], 1, reason: '$y-$m 的 1 号位置');
          expect(grid[firstWeekdayOffset(y, m) + days - 1], days);
          // 1 号之前、月末之后都必须是空格
          for (var i = 0; i < firstWeekdayOffset(y, m); i++) {
            expect(grid[i], isNull);
          }
          for (var i = firstWeekdayOffset(y, m) + days; i < 42; i++) {
            expect(grid[i], isNull);
          }
        }
      }
    });

    test('日期连续且不重复', () {
      final grid = monthGrid(2026, 2);
      final filled = grid.whereType<int>().toList();
      expect(filled, List<int>.generate(28, (i) => i + 1));
    });
  });

  group('clampDay 收敛到当月合法范围', () {
    test('超出月末的天数被收回', () {
      expect(clampDay(2026, 2, 31), 28);
      expect(clampDay(2024, 2, 31), 29);
      expect(clampDay(2026, 4, 31), 30);
      expect(clampDay(2026, 11, 31), 30);
    });

    test('正常值原样返回', () {
      expect(clampDay(2026, 9, 11), 11);
      expect(clampDay(2026, 1, 31), 31);
      expect(clampDay(2026, 2, 28), 28);
      expect(clampDay(2024, 2, 29), 29);
    });

    test('下界收敛到 1', () {
      expect(clampDay(2026, 9, 0), 1);
      expect(clampDay(2026, 9, -5), 1);
    });
  });
}
