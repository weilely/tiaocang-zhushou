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

/// push2 的**国债那一路**（`secid=171.CN10Y`）可用吗
///
/// 2026-09-30 实测：宿主的 [push2Available]（沪指 `1.000001`）放行了，
/// 可这两条联网用例里**取国债**的那一步失败 —— 同一个域名、不同 secid 的
/// 可用性并不一致（限流/单接口故障）。所以探活要贴着**这一个真实请求**，
/// 不能拿同域的另一个接口推断（本项目 2026-09-21 那条教训的又一实例）。
Future<bool> push2BondAvailable() async {
  try {
    final r = await http
        .get(Uri.parse('https://push2.eastmoney.com/api/qt/stock/get'
            '?fltt=2&invt=2&ut=$_ut&fields=f43,f57&secid=171.CN10Y'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body);
    final d = j is Map ? j['data'] : null;
    return d is Map && (d['f43'] as num?) != null;
  } catch (_) {
    return false;
  }
}

/// 东财**数据中心**（`datacenter.eastmoney.com`）可用吗 —— 10 年国债历史走它。
///
/// 又一个"同一家不同域名故障不同步"的例子：`push2` 正常不代表这个域名正常。
Future<bool> datacenterAvailable() async {
  try {
    const token = '894050c76af8597a853f5b408b759f5d';
    final r = await http
        .get(Uri.parse('https://datacenter.eastmoney.com/api/data/get'
            '?type=RPTA_WEB_TREASURYYIELD&sty=ALL&st=SOLAR_DATE&sr=-1'
            '&token=$token&ps=1&p=1&pageNo=1&pageNum=1'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body);
    return j is Map && j['result'] is Map;
  } catch (_) {
    return false;
  }
}
