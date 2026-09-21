import 'dart:convert';

import 'package:http/http.dart' as http;

/// 联网用例的公共探活
///
/// 为什么需要：东财的网关（尤其 `push2.eastmoney.com`）会**整站 502**，
/// 连最普通的指数都取不到 —— 2026-09-21 实测过一次。那时依赖它的联网用例
/// 全红，看起来像我把代码改坏了，其实只是上游故障。
///
/// 做法：用例先探活，不通就 `markTestSkipped` —— **数据断言一条不放松**，
/// 只是不把"上游挂了"算成自己的回归。
const String _ut = 'fa5fd1943c7b386f172d6893dbfba10b';

/// push2 网关现在可用吗（拿最普通的沪指探一下）
Future<bool> push2Available() async {
  try {
    final r = await http
        .get(Uri.parse('https://push2.eastmoney.com/api/qt/stock/get'
            '?fltt=2&invt=2&ut=$_ut&fields=f43,f57&secid=1.000001'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body);
    return j is Map && j['data'] is Map;
  } catch (_) {
    return false;
  }
}

/// push2 的 K 线网关（`push2his`）可用吗 —— 它和 push2 是两个域名，故障不同步
Future<bool> push2HisAvailable() async {
  try {
    final r = await http
        .get(Uri.parse('https://push2his.eastmoney.com/api/qt/stock/kline/get'
            '?secid=1.000001&klt=101&fqt=1&beg=20260901&end=20500101'
            '&fields1=f1&fields2=f51,f53'))
        .timeout(const Duration(seconds: 8));
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}
