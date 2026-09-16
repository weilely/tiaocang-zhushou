import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/ui/widgets/return_table.dart';

/// 首列「代码 + 名称」的宽度拟合规则。
///
/// `flutter test` 用的是等宽测试字体（每个字形宽度 = fontSize），
/// 所以行宽是可算的，断言不依赖真机字体度量。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const code = '025497';
  const codeStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
  const nameStyle = TextStyle(fontSize: 12);

  InlineSpan spanFor(String part) => TextSpan(
        children: [
          const TextSpan(text: code, style: codeStyle),
          if (part.isNotEmpty) TextSpan(text: ' $part', style: nameStyle),
        ],
      );

  String fit(String name, {double maxWidth = 132, int maxLines = 2}) => fitName(
        name: name,
        maxLines: maxLines,
        maxWidth: maxWidth,
        textScaler: TextScaler.noScaling,
        spanBuilder: spanFor,
      );

  /// 独立的“放得下吗”判定，用来验证 fitName 的返回结果真的不溢出
  bool fits(String part, {double maxWidth = 132, int maxLines = 2}) {
    final tp = TextPainter(
      text: spanFor(part),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: maxWidth);
    return !tp.didExceedMaxLines;
  }

  group('放得下就完整显示', () {
    test('短名称原样返回，不加省略号', () {
      expect(fit('易方达基金'), '易方达基金');
      expect(fit('易方达基金'), isNot(contains('…')));
    });

    test('宽度够大时超长名称也原样返回', () {
      const long = '易方达国证价值100ETF联接发起式A';
      expect(fit(long, maxWidth: 900), long);
    });
  });

  group('放不下时中间省略、保留末字符', () {
    const long = '易方达国证价值100ETF联接发起式A';

    test('确实被缩略了', () {
      final r = fit(long);
      expect(r, isNot(long));
      expect(r, contains('…'));
      expect(r.runes.length, lessThan(long.runes.length));
    });

    test('末字符（份额类别）被保留', () {
      expect(fit(long).endsWith('A'), isTrue);
      expect(fit('天弘中证光伏产业指数C').endsWith('C'), isTrue);
      expect(fit('华夏中证动漫游戏ETF联接发起式E').endsWith('E'), isTrue);
    });

    test('缩略结果真的放得下（所见即所测）', () {
      for (final n in [
        long,
        '天弘中证光伏产业指数C',
        '华夏中证动漫游戏ETF联接发起式E',
        '易方达黄金股指数发起式A',
      ]) {
        final r = fit(n);
        expect(fits(r), isTrue, reason: '「$r」应当放得下');
      }
    });

    test('缩略后仍保留开头的代码特征字', () {
      // 省略是砍中间，不是砍尾巴
      expect(fit(long).startsWith('易方达'), isTrue);
    });
  });

  group('边界与兜底', () {
    test('名称为空（或只有空白）返回空串，只显示代码', () {
      expect(fit(''), '');
      expect(fit('   '), '');
    });

    test('可用宽度为 0 时不测量、直接返回空串', () {
      expect(fit('易方达基金', maxWidth: 0), '');
      expect(fit('易方达基金', maxWidth: -10), '');
    });

    test('连「…末字符」都放不下时原样返回，交给 TextOverflow.ellipsis 兜底', () {
      const long = '易方达国证价值100ETF联接发起式A';
      expect(fit(long, maxWidth: 20), long);
    });

    test('只有一行时也能省略', () {
      const long = '易方达国证价值100ETF联接发起式A';
      final r = fit(long, maxLines: 1);
      expect(r, contains('…'));
      expect(r.endsWith('A'), isTrue);
      expect(fits(r, maxLines: 1), isTrue);
    });

    test('单字符名称不会崩', () {
      expect(fit('A', maxWidth: 900), 'A');
      final r = fit('A', maxWidth: 20);
      expect(r, isNotEmpty);
    });
  });
}
