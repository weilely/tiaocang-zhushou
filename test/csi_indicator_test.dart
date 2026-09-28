import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_indicator.dart';

import 'csi_indicator_fixture.dart';

/// 中证官网 indicator.xls：列名定位 / 取最新一行 / 真文件能被 excel_plus 读出来
void main() {
  /// 表头照实测（中英合写）
  const head = [
    '日期Date',
    '指数代码Index Code',
    '指数中文全称Chinese Name(Full)',
    '指数中文简称Index Chinese Name',
    '指数英文全称English Name(Full)',
    '指数英文简称Index English Name',
    '市盈率1（总股本）P/E1',
    '市盈率2（计算用股本）P/E2',
    '股息率1（总股本）D/P1',
    '股息率2（计算用股本）D/P2',
  ];

  List<String> row(String date, String code, String name, String pe1, String pe2,
          String dp1, String dp2) =>
      [date, code, '$name指数', name, 'CSI X', 'CSI X', pe1, pe2, dp1, dp2];

  group('按列名定位 + 取最新一行', () {
    test('乱序也给日期最大的那行（不依赖官网顺序）', () {
      final g = [
        head,
        row('20260903', '000922', '中证红利', '8.83', '11.06', '4.16', '4.13'),
        row('20260928', '000922', '中证红利', '8.74', '10.67', '4.21', '4.27'),
        row('20260925', '000922', '中证红利', '8.72', '10.73', '4.21', '4.25'),
      ];
      final it = parseIndicatorGrid(g)!;
      expect(it.date, '20260928');
      expect(it.code, '000922');
      expect(it.name, '中证红利'); // 取的是「简称」，不是「全称」
      expect(it.pe1, closeTo(8.74, 1e-9));
      expect(it.pe2, closeTo(10.67, 1e-9));
      expect(it.dp1, closeTo(4.21, 1e-9));
      expect(it.dp2, closeTo(4.27, 1e-9));
    });

    test('默认口径：PE 用总股本、股息率用计算用股本', () {
      final it = parseIndicatorGrid([
        head,
        row('20260928', '000922', '中证红利', '8.74', '10.67', '4.21', '4.27'),
      ])!;
      expect(it.pe, closeTo(8.74, 1e-9)); // pe1
      expect(it.dividendYield, closeTo(4.27, 1e-9)); // dp2
    });

    test('只有一个口径时退回另一个（有就给，别留空）', () {
      final g = [
        ['日期Date', '指数代码Index Code', '市盈率2（计算用股本）', '股息率1（总股本）'],
        ['20260928', '930740', '8.88', '4.33'],
      ];
      final it = parseIndicatorGrid(g)!;
      expect(it.pe, closeTo(8.88, 1e-9));
      expect(it.dividendYield, closeTo(4.33, 1e-9));
    });

    test('带千分位逗号也认', () {
      final g = [
        ['日期Date', '指数代码Index Code', '市盈率1（总股本）'],
        ['20260928', 'H30269', '1,234.5'],
      ];
      expect(parseIndicatorGrid(g)!.pe1, closeTo(1234.5, 1e-9));
    });

    test('表头不在第一行时（前面有说明行）也能找到', () {
      final g = [
        ['中证指数有限公司'],
        <String>[],
        head,
        row('20260928', '000922', '中证红利', '8.74', '10.67', '4.21', '4.27'),
      ];
      expect(parseIndicatorGrid(g)!.date, '20260928');
    });
  });

  group('认不出来就返回 null（界面照实说"没取到"）', () {
    test('空表 / 只有表头 / 没有日期列', () {
      expect(parseIndicatorGrid(const []), isNull);
      expect(parseIndicatorGrid([head]), isNull);
      expect(parseIndicatorGrid(const [
        ['指数代码Index Code', '市盈率1（总股本）'],
        ['000922', '8.74'],
      ]), isNull);
    });

    test('坏字节 / 不是表格 → null，不抛', () {
      expect(parseIndicatorBytes(const [1, 2, 3, 4]), isNull);
      expect(parseIndicatorBase64('这不是 base64'), isNull);
      expect(parseIndicatorBase64(''), isNull);
    });
  });

  group('真实文件（仓库里那份 8KB 样本）', () {
    test('excel_plus 能把 OLE2/BIFF8 读出来，且数值与实测一致', () {
      final it = parseIndicatorBase64(kCsiIndicator000922XlsBase64)!;
      expect(it.code, '000922');
      expect(it.name, '中证红利');
      expect(it.date, '20260928'); // 文件里最新的一条
      expect(it.pe1, closeTo(8.74, 0.001));
      expect(it.pe2, closeTo(10.67, 0.001));
      expect(it.dp1, closeTo(4.21, 0.001));
      expect(it.dp2, closeTo(4.27, 0.001));
      expect(it.dividendYield, closeTo(4.27, 0.001)); // 与蛋卷 4.26 口径接近
    });

    test('URL 拼法（可直接粘浏览器核对）', () {
      final src = CsiIndicatorSource();
      expect(
        src.urlOf('H30269'),
        'https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/'
        'file/autofile/indicator/H30269indicator.xls',
      );
    });
  });
}
