import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/csi_pe_hist.dart';

/// 中证 PE 历史（`indexCsiDsPe`）→ 自算分位（形状照 2026-09-29 实测响应）
void main() {
  String body(List<(String, Object?)> pts) {
    final rows = pts
        .map((p) => '{"tradeDate":"${p.$1}","indexCode":"930050","peg":${p.$2}}')
        .join(',');
    return '{"code":"200","data":[$rows]}';
  }

  test('分位 = 最新 PE 在历史里"低于它的样本占比"（越小越低估）', () {
    final st = parseCsiPeStat(body([
      ('20260101', 10.0),
      ('20260201', 20.0),
      ('20260301', 30.0),
      ('20260401', 40.0),
      ('20260501', 15.0), // 最新：只有 10 比它小 → 1/5 = 0.2
    ]))!;
    expect(st.pe, closeTo(15.0, 1e-9));
    expect(st.percentile, closeTo(0.2, 1e-9));
    expect(st.date, '20260501');
    expect(st.windowStart, '20260101');
    expect(st.samples, 5);
  });

  test('顺序被打乱也按日期取最新', () {
    final st = parseCsiPeStat(body([
      ('20260501', 15.0),
      ('20260101', 10.0),
      ('20260301', 30.0),
    ]))!;
    expect(st.date, '20260501');
    expect(st.windowStart, '20260101');
    expect(st.percentile, closeTo(1 / 3, 1e-9));
  });

  test('peg 缺失的点跳过（债券类没有 PE），全缺就返回 null', () {
    final st = parseCsiPeStat(
        '{"code":"200","data":[{"tradeDate":"20260101","peg":10.0},'
        '{"tradeDate":"20260201","peg":null},'
        '{"tradeDate":"20260301","peg":20.0}]}')!;
    expect(st.samples, 2);
    expect(st.date, '20260301');
    expect(parseCsiPeStat('{"code":"200","data":[{"tradeDate":"20260101","peg":null}]}'),
        isNull);
  });

  test('空数据 / 坏 JSON → null（界面据此说"没取到"）', () {
    expect(parseCsiPeStat('{"code":"200","data":[]}'), isNull);
    expect(parseCsiPeStat('{"code":"200","data":null}'), isNull);
    expect(parseCsiPeStat('不是 json'), isNull);
  });

  test('只有一个样本时分位给 0.5（不假装最低或最高）', () {
    final st = parseCsiPeStat(body([('20260101', 10.0)]))!;
    expect(st.samples, 1);
    expect(st.percentile, closeTo(0.5, 1e-9));
  });

  test('URL 拼法（可直接粘浏览器核对）', () {
    final src = CsiPeHistSource();
    expect(src.urlOf('930050'),
        'https://www.csindex.com.cn/csindex-home/perf/indexCsiDsPe?indexCode=930050');
  });
}
