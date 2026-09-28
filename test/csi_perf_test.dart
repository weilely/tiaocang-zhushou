import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_perf.dart';

/// 中证 `index-perf` 解析（形状照 2026-09-29 实测响应）
void main() {
  const twoDays = '{"code":"200","msg":"Success","data":['
      '{"tradeDate":"20260925","indexCode":"000922","indexNameCn":"中证红利",'
      '"open":5700.0,"high":5786.14,"low":5701.66,"close":5719.05,'
      '"change":0.63,"changePct":0.01,"consNumber":100.0,"peg":8.7},'
      '{"tradeDate":"20260928","indexCode":"000922","indexNameCn":"中证红利",'
      '"open":5700.0,"high":5786.14,"low":5701.66,"close":5725.10,'
      '"change":6.05,"changePct":0.11,"consNumber":100.0,"peg":8.62}]}';

  test('取最后一条：PE 来自 peg 字段（官网把 PE 叫 peg）', () {
    final p = parseCsiPerfLatest(twoDays)!;
    expect(p.date, '20260928');
    expect(p.pe, closeTo(8.62, 1e-9));
    expect(p.close, closeTo(5725.10, 1e-9));
    expect(p.consNumber, 100);
    expect(p.name, '中证红利');
  });

  test('返回顺序不是升序时，按 tradeDate 挑最大的那条', () {
    const reversed = '{"code":"200","data":['
        '{"tradeDate":"20260928","peg":8.62,"close":5725.10},'
        '{"tradeDate":"20260925","peg":8.7,"close":5719.05}]}';
    final p = parseCsiPerfLatest(reversed)!;
    expect(p.date, '20260928');
    expect(p.pe, closeTo(8.62, 1e-9));
  });

  test('字段缺失留 null，不编 0（债券指数可能没有 peg）', () {
    final p = parseCsiPerfLatest(
        '{"code":"200","data":[{"tradeDate":"20260928","close":1234.5}]}')!;
    expect(p.pe, isNull);
    expect(p.consNumber, isNull);
    expect(p.close, closeTo(1234.5, 1e-9));
  });

  test('空数据 / 坏 JSON / 缺日期 → null（界面据此说"暂无"）', () {
    expect(parseCsiPerfLatest('{"code":"200","data":[]}'), isNull);
    expect(parseCsiPerfLatest('{"code":"200","data":null}'), isNull);
    expect(parseCsiPerfLatest('not json'), isNull);
    expect(parseCsiPerfLatest('{"code":"200","data":[{"peg":8.6}]}'), isNull);
  });
}
