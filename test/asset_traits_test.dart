import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/asset_traits.dart';
import 'package:invest_tracker/data/models.dart';

/// 标的类型能力表：三种类型到底哪里不一样，只在这张表里说
///
/// 起因：用户问「持有股票或 ETF，买卖与场外基金的逻辑是不是不一样，
/// 怎么兼顾差异又不失统一的 UI 风格」。答案＝界面骨架一套，差异落在这张表。
void main() {
  group('场外基金', () {
    final t = AssetKind.fund.traits;

    test('单位是份、按场外口径显示两位小数、不按手', () {
      expect(t.unit, '份');
      expect(t.unitIsFund, isTrue);
      expect(t.lotSize, 1);
    });

    test('价格是一天一条的净值、有盘中估值、买入先填金额', () {
      expect(t.priceIsLive, isFalse);
      expect(t.hasEstimate, isTrue);
      expect(t.buyByAmount, isTrue);
      expect(t.priceLabel, '最新净值');
      expect(t.priceDateLabel, '净值日期');
    });
  });

  group('场内（ETF / 股票）', () {
    for (final kind in [AssetKind.etf, AssetKind.stock]) {
      test('${kind.label}：实时价、按手、买入先填股数', () {
        final t = kind.traits;
        expect(t.priceIsLive, isTrue);
        expect(t.hasEstimate, isFalse, reason: '场内有实时价，没有"预估"一说');
        expect(t.buyByAmount, isFalse);
        expect(t.lotSize, 100);
        expect(t.unitIsFund, isFalse);
        expect(t.priceLabel, '最新价');
        expect(t.priceDateLabel, '行情日期');
      });
    }

    test('ETF 的份额习惯上仍说「份」，股票说「股」', () {
      expect(AssetKind.etf.traits.unit, '份');
      expect(AssetKind.stock.traits.unit, '股');
    });
  });

  test('指数（基准线）也有实时点位与单位，不会漏分支', () {
    final t = AssetKind.other.traits;
    expect(t.priceIsLive, isTrue);
    expect(t.unit, '点');
    expect(t.hasEstimate, isFalse);
  });

  test('每种类型都拿得到一张能力表（switch 必须穷尽）', () {
    for (final k in AssetKind.values) {
      expect(AssetTraits.of(k).priceLabel, isNotEmpty, reason: '${k.label} 缺能力表');
    }
  });
}
