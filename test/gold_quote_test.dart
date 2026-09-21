import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/market_api.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/data/nav_models.dart';

/// 黄金（上金所现货 / 沪金期货）接入「行情指标」
///
/// 要点：
/// ① 代码写成 `em:<东财 secid>`（黄金9999 = `118.AU9999`、沪金主连 = `113.aum`），
///    因为这类品种不属沪深两市，`sh/sz/bj` 那套推不出它们的 secid；
/// ② 取数走**和持仓同一条** `fetchExchangeQuotes`（批量失败会逐只兜底）——
///    早先只调批量那一条，批量接口一被限流黄金就永远是 `--`。
/// 造一个「非沪深市场」的标的：`code` 直接给完整东财 secid
Asset em(String secid) =>
    Asset(code: secid, name: '', kind: AssetKind.etf, market: 'EM');

void main() {
  group('secidFor：EM 直接把代码当 secid', () {
    test('黄金 / 期货的完整 secid 原样返回', () {
      expect(
        MarketService.secidFor(em('118.AU9999')),
        '118.AU9999',
      );
      expect(
        MarketService.secidFor(em('113.aum')),
        '113.aum',
      );
    });

    test('EM 但没带市场点号 → null（拼不出合法 secid）', () {
      expect(
        MarketService.secidFor(em('AU9999')),
        isNull,
      );
    });

    test('沪深北照旧按市场号推（别被 EM 分支带坏）', () {
      expect(MarketService.secidFor(Asset(code: '000001', name: '', kind: AssetKind.stock, market: 'SH')),
          '1.000001');
      expect(MarketService.secidFor(Asset(code: '399006', name: '', kind: AssetKind.stock, market: 'SZ')),
          '0.399006');
      expect(MarketService.secidFor(Asset(code: '899050', name: '', kind: AssetKind.stock, market: 'BJ')),
          '0.899050');
    });
  });

  group('flipSecid：只翻 A 股那种 <1|0>.<6位数字>', () {
    test('A 股正常翻转', () {
      expect(MarketService.flipSecid('1.000001'), '0.000001');
      expect(MarketService.flipSecid('0.399006'), '1.399006');
    });

    test('黄金/期货的 secid 不能被翻（翻了会打一次不存在的请求）', () {
      expect(MarketService.flipSecid('118.AU9999'), '118.AU9999');
      expect(MarketService.flipSecid('113.aum'), '113.aum');
    });

    test('奇形怪状的原样返回', () {
      expect(MarketService.flipSecid(''), '');
      expect(MarketService.flipSecid('118'), '118');
      expect(MarketService.flipSecid('.x'), '.x');
    });
  });

  group('分类与命名', () {
    test('em: 代码归到 other（不能混进沪深那两条行情通道）', () {
      expect(const IndexEntry(code: 'em:118.AU9999').group, 'other');
      expect(const IndexEntry(code: 'sz159263', kind: 'etf').group, 'etf');
      expect(const IndexEntry(code: 'sh000001').group, 'broad');
      expect(const IndexEntry(code: 'sz399006').group, 'broad');
    });

    test('预设表里有黄金9999；沪金主连已按用户要求删除', () {
      expect(MarketIndex.byCode('em:118.AU9999')?.name, '黄金9999');
      expect(MarketIndex.byCode('em:113.aum'), isNull);
    });

    test('normalizeIndexCode 不改动 em: 代码', () {
      expect(normalizeIndexCode(' em:118.AU9999 '), 'em:118.AU9999');
    });
  });

  // 联网：证明设备上真能取到（走应用真实的那条两级路径）。
  // 东财网关抽风时**跳过**而不是假红 —— 2026-09-21 实测 push2.eastmoney.com
  // 会整站 502，连普通指数都取不到。
  group('联网（网关不可用时跳过）', () {
    test('fetchExchangeQuotes 能取到黄金9999', () async {
      Map<String, Quote> got;
      try {
        got = await MarketService().fetchExchangeQuotes([em('118.AU9999')]);
      } catch (e) {
        markTestSkipped('push2 当前不可用：$e');
        return;
      }
      final au = got['AU9999'];
      if (au == null) {
        markTestSkipped('push2 没返回黄金行情（网关/网络问题）');
        return;
      }
      // 元/克：几百块量级。缩放写错会明显越界
      expect(au.price, greaterThan(100));
      expect(au.price, lessThan(10000));
      expect(au.changePct.abs(), lessThan(20));
      expect(au.name, contains('黄金'));
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
