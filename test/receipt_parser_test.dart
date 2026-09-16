import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/securities_repo.dart';
import 'package:invest_tracker/logic/receipt_parser.dart';

/// 拍照导入的解析口径
///
/// 老实现的毛病：把每一行文字都当成一笔持仓（标题、更新时间也变成行），
/// 数值靠「前两个小数 = 份额、成本」硬凑（日期 09-16 就被吃成份额 9、成本 16）。
/// 现在改成：**认标签 → 按块/锚点分段 → 模糊取值 → 交叉校验 → 存疑的标出来**。
void main() {
  // ---- 测试用的"基础数据库" ----
  const securities = <String, SecurityRow>{
    '021362': SecurityRow(
        code: '021362',
        kind: 'fund',
        name: '易方达黄金股指数发起式A',
        market: ''),
    '510300': SecurityRow(
        code: '510300', kind: 'etf', name: '沪深300ETF华泰柏瑞', market: 'SH'),
    '025497': SecurityRow(
        code: '025497',
        kind: 'fund',
        name: '易方达国证价值100ETF联接发起式A',
        market: ''),
  };

  Future<SecurityRow?> byCode(String code) async => securities[code];

  Future<List<SecurityRow>> byName(String name) async {
    final kw = name.replaceAll(RegExp(r'\s'), '');
    return securities.values
        .where((s) => s.name.contains(kw) || s.code.contains(kw))
        .toList();
  }

  OcrLine line(String text, double left, double top,
          {double w = 90, double h = 18, int block = 0}) =>
      OcrLine(
          text: text, left: left, top: top, right: left + w, bottom: top + h, block: block);

  group('工具函数', () {
    test('金额识别：千分位、万/亿、百分号与日期都要能分辨', () {
      expect(parseAmount('1,234.56'), closeTo(1234.56, 1e-9));
      expect(parseAmount('30,000'), closeTo(30000, 1e-9));
      expect(parseAmount('1.2万'), closeTo(12000, 1e-9));
      expect(parseAmount('3亿'), closeTo(3e8, 1e-9));
      expect(parseAmount('-1,234.00'), closeTo(-1234.0, 1e-9));
      // 这些都不是数值字段该吃的东西
      expect(parseAmount('2026-09-16'), isNull);
      expect(parseAmount('09-16'), isNull);
      expect(parseAmount('15:03'), isNull);
      expect(parseAmount('-2.18%'), isNull);
    });

    test('代码识别：混在文字里、OCR 把 O/I 认错也能救回来', () {
      expect(parseSecurityCode('代码 021362'), '021362');
      expect(parseSecurityCode('510300 沪深300ETF'), '510300');
      expect(parseSecurityCode('02I362'), '021362');
      expect(parseSecurityCode('没有代码'), isNull);
    });

    test('标签归一化：全角冒号、空格、括号都要认', () {
      expect(normalizeText('份额 ：'), '份额');
      expect(labelFieldOf('持有份额'), 'shares');
      expect(labelFieldOf('持仓市值(元)'), 'amount');
      expect(labelFieldOf('成本单价'), 'cost');
      expect(labelFieldOf('这不是标签这是很长的一句话'), isNull);
    });

    test('名称相似度：包含、去后缀、二元组', () {
      expect(nameSimilarity('沪深300ETF华泰柏瑞', '沪深300ETF华泰柏瑞'), 1);
      expect(nameSimilarity('易方达黄金股指数发起式A', '易方达黄金股指数发起式'), greaterThan(0.8));
      expect(nameSimilarity('易方达黄金股', '易方达黄金股指数发起式A'), greaterThan(0.5));
      expect(nameSimilarity('贵州茅台', '沪深300ETF'), lessThan(0.3));
    });
  });

  group('表格版：有表头就按列取', () {
    final lines = [
      line('代码', 10, 10, w: 50),
      line('基金名称', 90, 10, w: 80),
      line('持有份额', 260, 10, w: 70),
      line('成本单价', 360, 10, w: 70),
      line('持仓市值', 460, 10, w: 70),
      line('021362', 10, 60, w: 60),
      line('易方达黄金股指数发起式A', 90, 60, w: 180),
      line('30,000.00', 260, 60, w: 80),
      line('1.8617', 360, 60, w: 60),
      line('51,627.00', 460, 60, w: 80),
      // 干扰行：标题与更新时间，老实现会把它们当持仓
      line('我的持仓 行情更新 09-16 15:03', 10, 300, w: 260),
    ];

    test('认出表头，按列取值，干扰行不生成垃圾数据', () async {
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.headerFound, isTrue);
      expect(r.rows, hasLength(1));
      final row = r.rows.single;
      expect(row.code, '021362');
      expect(row.name, '易方达黄金股指数发起式A');
      expect(row.matched, isTrue);
      expect(row.shares, closeTo(30000, 1e-9));
      expect(row.costPrice, closeTo(1.8617, 1e-9));
      expect(row.needsReview, isFalse, reason: '列都对齐了，不该要求核对');
    });

    test('份额×成本 与市值不一致时不乱改成本（市值 = 份额×净值，不是×成本）', () async {
      final dirty = [
        ...lines.sublist(0, 5),
        line('021362', 10, 60, w: 60),
        line('易方达黄金股指数发起式A', 90, 60, w: 180),
        line('30,000.00', 260, 60, w: 80),
        line('9.9999', 360, 60, w: 60), // 用户填的成本，要原样带出来
        line('51,627.00', 460, 60, w: 80),
      ];
      final r = await parseHoldingRows(dirty, byCode: byCode, byName: byName);
      final row = r.rows.single;
      expect(row.costPrice, closeTo(9.9999, 1e-4));
      expect(row.shares, closeTo(30000, 1e-9));
    });

    test('份额×净值 与市值对不上时，把份额标成待核对', () async {
      final r = await parseHoldingRows([
        line('代码', 10, 10, w: 50),
        line('基金名称', 90, 10, w: 80),
        line('持有份额', 260, 10, w: 70),
        line('单位净值', 360, 10, w: 70),
        line('持仓市值', 460, 10, w: 70),
        line('510300', 10, 60, w: 60),
        line('沪深300ETF华泰柏瑞', 90, 60, w: 180),
        line('5,021.00', 260, 60, w: 80),
        line('4.5193', 360, 60, w: 60),
        // 5021 × 4.5193 = 22691，写个明显对不上的市值
        line('9,999.00', 460, 60, w: 80),
      ], byCode: byCode, byName: byName);
      final row = r.rows.single;
      expect(row.weak, contains('shares'));
    });
  });

  group('卡片版：一张卡一块，标签和值可以不在同一行', () {
    test('按锚点分段：名称行 + 代码行属于同一张卡片', () async {
      final lines = [
        // 第 0 块 = 卡片 A
        line('易方达黄金股指数发起式A', 20, 100, w: 200, block: 0),
        line('021362', 20, 130, w: 70, block: 0),
        line('持有份额', 20, 170, w: 70, block: 0),
        line('30,000.00', 20, 195, w: 80, block: 0),
        line('成本单价', 160, 170, w: 70, block: 0),
        line('1.8617', 160, 195, w: 60, block: 0),
        // 第 1 块 = 卡片 B
        line('沪深300ETF华泰柏瑞', 20, 400, w: 180, block: 1),
        line('510300', 20, 430, w: 70, block: 1),
        line('持有份额: 5,021', 20, 470, w: 140, block: 1),
        line('成本单价: 3.1459', 20, 495, w: 140, block: 1),
      ];
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.rows, hasLength(2));

      final a = r.rows.first;
      expect(a.code, '021362');
      expect(a.shares, closeTo(30000, 1e-9));
      expect(a.costPrice, closeTo(1.8617, 1e-9));

      final b = r.rows.last;
      expect(b.code, '510300');
      expect(b.name, '沪深300ETF华泰柏瑞');
      expect(b.shares, closeTo(5021, 1e-9));
      expect(b.costPrice, closeTo(3.1459, 1e-9));
    });

    test('只有名称、没有代码时靠模糊匹配认出来', () async {
      final lines = [
        line('易方达黄金股指数发起式', 20, 100, w: 190, block: 0),
        line('份额 30,000', 20, 130, w: 120, block: 0),
        line('成本 1.8617', 20, 155, w: 110, block: 0),
      ];
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.rows, hasLength(1));
      expect(r.rows.single.code, '021362');
      expect(r.rows.single.name, '易方达黄金股指数发起式A');
      expect(r.rows.single.shares, closeTo(30000, 1e-9));
    });

    test('只有份额 + 市值（没有成本/净值）→ 成本留空并标成待核对', () async {
      final lines = [
        line('510300 沪深300ETF华泰柏瑞', 20, 100, w: 200, block: 0),
        line('持有份额', 20, 130, w: 70, block: 0),
        line('5,021.00', 20, 155, w: 70, block: 0),
        line('持仓市值', 160, 130, w: 70, block: 0),
        line('22,845.55', 160, 155, w: 80, block: 0),
      ];
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      final row = r.rows.single;
      expect(row.shares, closeTo(5021, 1e-9));
      // 市值 ÷ 份额 得到的是**净值**，不能拿来当成本（会把盈亏算错）
      expect(row.costPrice, isNull);
      expect(row.weak, contains('costPrice'));
      expect(r.reviewRows, 1);
    });

    test('只有净值、没有成本 → 用净值兜底并标待核对', () async {
      final lines = [
        line('510300 沪深300ETF华泰柏瑞', 20, 100, w: 200, block: 0),
        line('持有份额 5,021.00', 20, 130, w: 150, block: 0),
        line('单位净值 4.5193', 20, 155, w: 140, block: 0),
      ];
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      final row = r.rows.single;
      expect(row.shares, closeTo(5021, 1e-9));
      expect(row.costPrice, closeTo(4.5193, 1e-4));
      expect(row.weak, contains('costPrice'));
    });

    test('完全没有标的线索的块被丢掉，不计入结果', () async {
      final lines = [
        line('行情更新 09-16 15:03', 20, 10, w: 200, block: 0),
        line('我的持仓', 20, 40, w: 80, block: 0),
        line('易方达黄金股指数发起式A 021362', 20, 100, w: 300, block: 1),
        line('持有份额 30,000', 20, 130, w: 140, block: 1),
      ];
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.rows, hasLength(1));
      expect(r.rows.single.code, '021362');
      expect(r.orphanLines, greaterThan(0));
    });
  });

  group('行分组', () {
    OcrLine l(String text, double left, double top, {double w = 60, double h = 20}) =>
        OcrLine(text: text, left: left, top: top, right: left + w, bottom: top + h);

    test('同一行的文字被聚成一行并按 x 排序', () {
      final rows = groupLinesIntoRows([
        l('510300', 300, 100),
        l('沪深300ETF', 40, 102),
        l('5,000.00', 500, 99),
      ]);
      expect(rows.length, 1);
      expect(rows.first.map((e) => e.text).toList(),
          ['沪深300ETF', '510300', '5,000.00']);
    });

    test('纵坐标差超过阈值时切成两行', () {
      final rows = groupLinesIntoRows([l('第一行', 40, 100), l('第二行', 40, 200)]);
      expect(rows.length, 2);
    });

    test('只有代码、没有任何标签时：标的认出来，份额/成本留空等用户填', () async {
      final r = await parseHoldingRows([
        l('沪深300ETF华泰柏瑞', 40, 100, w: 200),
        l('510300', 300, 100),
        l('5,000.00', 500, 100),
        l('3.1400', 620, 100),
      ], byCode: byCode, byName: byName);
      expect(r.rows, hasLength(1));
      expect(r.rows.single.code, '510300');
      expect(r.rows.single.matched, isTrue);
      // 没有标签就不硬猜数字（老实现会把它们当份额/成本，经常猜错）
      expect(r.rows.single.shares, isNull);
      expect(r.rows.single.costPrice, isNull);
      expect(r.rows.single.needsReview, isTrue);
    });

    test('纯数字噪声行不会变成标的', () async {
      final r = await parseHoldingRows([
        l('123.45', 500, 100),
        l('99.9%', 700, 100),
      ], byCode: byCode, byName: byName);
      expect(r.rows, isEmpty);
      expect(r.orphanLines, greaterThan(0));
    });
  });

  // ---------------- 真实截图：天天基金「持仓详情」 ----------------
  //
  // 版式（用户提供的微信图片_20260916143728_13_23.jpg）：
  //   易方达国证价值100ETF联接发起式A
  //   025497  中风险(R3)
  //   资产(元)  189,797.65
  //   最新净值 1.1001    日涨跌 -0.07%
  //   单位成本 1.0886    持仓成本 187,812.86
  //   持有份额 172,527.63 可用份额 172,527.63
  //   累计收益 +2,346.62 资产占比 57.01%
  group('真实截图：持仓详情', () {
    OcrLine l(String text, double left, double top, {double w = 80, double h = 20}) =>
        OcrLine(text: text, left: left, top: top, right: left + w, bottom: top + h);

    final lines = [
      l('持仓详情', 400, 40, w: 160),
      l('易方达国证价值100ETF联接发起式A', 40, 150, w: 460),
      l('025497', 40, 190, w: 90),
      l('中风险(R3)', 140, 190, w: 120),
      l('资产(元)', 300, 250, w: 120),
      l('189,797.65', 200, 300, w: 260),
      l('日收益(09-14)', 40, 400, w: 160),
      l('持仓收益', 260, 400, w: 120),
      l('持仓收益率', 480, 400, w: 120),
      l('-138.02', 40, 430, w: 110),
      l('+1,984.79', 240, 430, w: 130),
      l('+1.06%', 480, 430, w: 100),
      l('最新净值', 40, 500, w: 110),
      l('1.1001', 200, 500, w: 90),
      l('日涨跌', 380, 500, w: 90),
      l('-0.07%', 520, 500, w: 100),
      l('单位成本', 40, 560, w: 110),
      l('1.0886', 200, 560, w: 90),
      l('持仓成本', 380, 560, w: 110),
      l('187,812.86', 520, 560, w: 140),
      l('持有份额', 40, 620, w: 110),
      l('172,527.63', 200, 620, w: 130),
      l('可用份额', 380, 620, w: 110),
      l('172,527.63', 520, 620, w: 130),
      l('累计收益', 40, 680, w: 110),
      l('+2,346.62', 200, 680, w: 130),
      l('资产占比', 380, 680, w: 110),
      l('57.01%', 520, 680, w: 100),
      l('交易记录', 40, 800, w: 110),
      l('收益明细', 200, 800, w: 110),
      l('分红方式', 40, 900, w: 110),
      l('红利再投资', 300, 900, w: 130),
    ];

    test('代码/名称/份额/单位成本都取对，且不把「持仓成本」当单价', () async {
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.rows, isNotEmpty);
      final row = r.rows.first;
      expect(row.code, '025497');
      expect(row.name, '易方达国证价值100ETF联接发起式A');
      expect(row.matched, isTrue);
      expect(row.shares, closeTo(172527.63, 0.01));
      // 单位成本 1.0886（不是总成本 187,812.86）
      expect(row.costPrice, closeTo(1.0886, 1e-4));
    });

    test('不会产出垃圾行（页头、标签、分红方式都别当持仓）', () async {
      final r = await parseHoldingRows(lines, byCode: byCode, byName: byName);
      expect(r.rows.length, lessThanOrEqualTo(2));
      for (final row in r.rows) {
        expect(row.code.isNotEmpty || row.matched, isTrue);
      }
    });
  });

  // ---------------- 天天基金「持仓详情」：整页被 OCR 合成一行 ----------------
  //
  // 实测这台机器上 ML Kit 把整页读成了很少的几个 cell，
  // 几何对位取不到份额 —— 所以还要有"直接在文字流里扫"的兜底。
  group('整页合成一行的截图', () {
    OcrLine l(String text, double left, double top, {double w = 80, double h = 20}) =>
        OcrLine(text: text, left: left, top: top, right: left + w, bottom: top + h);

    // 这一串就是设备上「识别原文」里真实出现的内容
    final page = '09:16 然金:面60 持仓详情 易方达国证价值100ETF联接发起式A ,详情> 025497 中风险(R3) '
        '|资产元)0注 189,797.65 日收益(09-14) 持仓收益 持仓收益率-138.02 +1,984.79 +1.06% '
        '最新净值 1.1001 日涨跌 -0.07% 单位成本 1.0886 持仓成本 187,812.86 '
        '持有份额 172,527.63 可用份额ⓘ 172,527.63 累计收益 +2,346.62 资产占比 57.01% '
        '目 交易记录 收益明细 份额明细 我的定投';

    test('份额、单位成本都能填上（不把总成本当单价）', () async {
      final r = await parseHoldingRows(
        [l(page, 20, 100, w: 900, h: 900)],
        byCode: byCode,
        byName: byName,
      );
      expect(r.rows, hasLength(1));
      final row = r.rows.single;
      expect(row.code, '025497');
      expect(row.shares, closeTo(172527.63, 0.01));
      expect(row.costPrice, closeTo(1.0886, 1e-4));
    });
  });
}