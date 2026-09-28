/// 「指数估值」取数：**基金/指数估值查询**用的那条链路（2026-09-28 实测打通）。
///
/// 为什么需要三个环节：公开源里**能拿到指数股息率的一共两处** —— ①蛋卷的
/// JSON（本文件走的这条，覆盖面小但字段全）；②**中证指数官网的 `indicator.xls`**
/// （`https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/file/autofile/indicator/<代码>indicator.xls`
/// ，只有 .xls 一种格式，含 `市盈率1/市盈率2/股息率1/股息率2`，**覆盖全部中证指数**，
/// 但需要自己解 OLE2/BIFF —— **待接入**）。蛋卷按"符号"查
/// （如 `SH000922` / `CSIH30269`），所以要先由**指数名**解析出代码。
///
/// ①**指数名 → 代码**：东财联想 `searchapi.eastmoney.com/api/suggest/get?input=<名>&type=14`
///   （响应里 `SecurityTypeName == '指数'` 才是指数；`QuoteID` 形如 `1.000922` /
///   `2.H30269` / `0.980080`）
/// ②**代码 → 蛋卷符号**：沪市 `SH<代码>`、深/国证 `SZ<代码>`、中证系
///   （H 开头或 9 开头）`CSI<代码>` —— 实测 `1.000922 → SH000922` ✅、
///   `2.H30269 → CSIH30269` ✅。**到底哪个对，用蛋卷返回的 `name` 反查验证**
///   （所以这里会逐个候选试，成功即止，**不猜**）
/// ③**取估值**：蛋卷 `danjuanfunds.com/djapi/index_eva/detail/<符号>` →
///   `pe / pb / yeild(股息率，小数) / roe / pe_percentile / pb_percentile /
///   begin_at(分位窗口起点) / date`
///
/// ⚠️ **覆盖率是硬上限**：蛋卷只收录一部分指数（实测收录：中证红利 / 红利低波 /
/// 300红利LV / 上证红利 / 沪深300 / 中证500 / 创业板 / 深证红利 …；**未收录**：
/// 红利价值 H30270、红利质量 931468、国证成长100 980080、国证价值100 980081、
/// 国证自由现金流 980092、港股通红利低波 987016、沪深港黄金产业 等）。
/// 未收录时界面**如实说"这个指数暂时没有估值数据源"**，不许拿别的指数顶替。
///
/// 其他源都试过且**拿不到**：中证官网 `index-perf`（只有 PE，股息率在那个 .xls 里）、
/// 国证官网（接口 404，980080/980081/980092 都取不到）、同花顺 A 股估值（只有
/// PE/PB/PS/PCF，且标的检索不覆盖指数）、东财 `datacenter-web`（本机 300s 超时）→
/// 天天基金「指数宝」因此也不可用（要登录 + 走这个域）。**华夏「红色火箭」是微信
/// 小程序，没有对外接口**。所以别再指望它们。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

double? _numOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 一个指数候选（来自东财联想）
class IndexCandidate {
  /// 东财的 `QuoteID`，如 `1.000922`（市场号.代码）
  final String quoteId;

  /// 纯代码，如 `000922` / `H30269`
  final String code;

  /// 指数名，如 `中证红利`
  final String name;

  const IndexCandidate({
    required this.quoteId,
    required this.code,
    required this.name,
  });

  /// 差一点就成「蛋卷符号」的候选列表（**按可能性排序，逐个试**）
  ///
  /// 实测：沪市 `SH`、中证系（H/9 开头）`CSI`；深市与国证放 `SZ`。
  /// 不做"按市场号硬判"——`2.H30269` 的 2 是深市号，但蛋卷要的是 `CSIH30269`。
  List<String> get symbolGuesses {
    final out = <String>[];
    void add(String s) {
      if (!out.contains(s)) out.add(s);
    }

    if (quoteId.startsWith('1.')) add('SH$code');
    add('CSI$code'); // 中证系（H30269 / 930740 / 931468 …）
    add('SZ$code'); // 深市 / 国证
    if (!quoteId.startsWith('1.')) add('SH$code');
    return out;
  }
}

/// 从东财联想响应里挑出**指数**候选（纯函数，可单测）
List<IndexCandidate> parseEastmoneySuggest(Object? json) {
  if (json is! Map) return const [];
  final table = json['QuotationCodeTable'];
  if (table is! Map) return const [];
  final data = table['Data'];
  if (data is! List) return const [];
  final out = <IndexCandidate>[];
  for (final it in data) {
    if (it is! Map) continue;
    if (_str(it['SecurityTypeName']) != '指数') continue;
    final code = _str(it['Code']);
    final name = _str(it['Name']);
    if (code.isEmpty || name.isEmpty) continue;
    out.add(IndexCandidate(
      quoteId: _str(it['QuoteID']),
      code: code,
      name: name,
    ));
  }
  return out;
}

/// 一个指数的估值（蛋卷 `index_eva/detail`）
class IndexValuation {
  /// 蛋卷符号（如 `SH000922`）
  final String symbol;

  /// 蛋卷返回的指数名（**用来验证符号猜对了**）
  final String name;

  /// 市盈率
  final double? pe;

  /// 市净率
  final double? pb;

  /// **股息率（小数）**：0.0426 = 4.26%
  final double? yeild;

  /// 净资产收益率（小数）
  final double? roe;

  /// PE 分位（0~1）
  final double? pePercentile;

  /// PB 分位（0~1）
  final double? pbPercentile;

  /// 分位窗口起点（蛋卷 `begin_at`，毫秒）
  final DateTime? windowStart;

  /// 数据日期（蛋卷 `date`，形如 `2026-09-28`）
  final String date;

  /// 估值标签（蛋卷 `eva_type`：low / middle / high）
  final String evaType;

  const IndexValuation({
    required this.symbol,
    required this.name,
    this.pe,
    this.pb,
    this.yeild,
    this.roe,
    this.pePercentile,
    this.pbPercentile,
    this.windowStart,
    this.date = '',
    this.evaType = '',
  });

  static IndexValuation? fromJson(String symbol, Object? json) {
    if (json is! Map) return null;
    final d = json['data'];
    if (d is! Map) return null;
    final name = _str(d['name']);
    if (name.isEmpty) return null; // 名字都没有 = 这个符号蛋卷不认
    final begin = _numOrNull(d['begin_at']);
    return IndexValuation(
      symbol: symbol,
      name: name,
      pe: _numOrNull(d['pe']),
      pb: _numOrNull(d['pb']),
      yeild: _numOrNull(d['yeild']),
      roe: _numOrNull(d['roe']),
      pePercentile: _numOrNull(d['pe_percentile']),
      pbPercentile: _numOrNull(d['pb_percentile']),
      windowStart: begin == null || begin <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(begin.toInt()),
      date: _str(d['date']),
      evaType: _str(d['eva_type']),
    );
  }
}

/// 「指数估值」的取数客户端
class IndexEvaSource {
  final http.Client _client;
  final String base;

  IndexEvaSource({http.Client? client, this.base = 'https://danjuanfunds.com'})
      : _client = client ?? http.Client();

  static const _emBase = 'https://searchapi.eastmoney.com';
  static const _emToken = 'D43BF722C8E33BDC906FB84D85E326E8';

  /// 按名字/代码联想指数（东财）。失败返回空表（搜索类失败不该炸页面）
  Future<List<IndexCandidate>> search(
    String query, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final url = Uri.parse('$_emBase/api/suggest/get'
          '?input=${Uri.encodeQueryComponent(q)}'
          '&type=14&token=$_emToken&count=40');
      final res = await _client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.eastmoney.com/',
      }).timeout(timeout);
      if (res.statusCode != 200) return const [];
      return parseEastmoneySuggest(
          jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true)));
    } catch (_) {
      return const [];
    }
  }

  /// 取一个蛋卷符号的估值；符号不被识别（蛋卷没收录）时返回 null
  Future<IndexValuation?> fetch(
    String symbol, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final res = await _client.get(
        Uri.parse('$base/djapi/index_eva/detail/$symbol'),
        headers: {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://danjuanfunds.com/',
        },
      ).timeout(timeout);
      if (res.statusCode != 200) return null;
      return IndexValuation.fromJson(
          symbol, jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true)));
    } catch (_) {
      return null;
    }
  }

  /// 从一个候选里试出**真正可用**的蛋卷估值：逐个符号猜。
  ///
  /// 给了 [expectName] 时**优先要名字对得上的那个**（中证目录里的官方名 vs 蛋卷
  /// 返回的名）：全都不对但又确实取到了，就把它当兜底返回 —— **由界面把两个名字
  /// 都显示出来**，而不是悄悄拿别的指数的估值冒充（规矩：拿不准就别编）。
  ///
  /// 返回 null = 这个指数蛋卷没收录（或网络失败）——**界面必须如实说**。
  Future<IndexValuation?> fetchCandidate(
    IndexCandidate c, {
    String? expectName,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    IndexValuation? fallback;
    for (final s in c.symbolGuesses) {
      final v = await fetch(s, timeout: timeout);
      if (v == null) continue;
      if (expectName == null || indexNameMatches(v.name, expectName)) return v;
      fallback ??= v;
    }
    return fallback;
  }
}

/// 只有代码（例如来自中证官方目录、没有东财 `QuoteID`）时的蛋卷符号猜测。
///
/// 与 [IndexCandidate.symbolGuesses] 的差别：没有市场号可参考，只能按**代码形状**
/// 排先后（都是实测过的规律）：中证系（`H`/`9` 开头）先试 `CSI`；沪市 `000xxx`
/// 先试 `SH`；深市/国证（`399`/`98` 开头）先试 `SZ`。**成不成由蛋卷返回的 name 判**。
List<String> symbolGuessesForCode(String rawCode) {
  final code = rawCode.trim().toUpperCase();
  final out = <String>[];
  void add(String s) {
    if (!out.contains(s)) out.add(s);
  }

  if (code.isEmpty) return out;
  // `98`/`399` 开头是深市、国证（980xxx 也是 9 开头，所以要先判它）；
  // 其余 9 开头（93xxxx）与 H 开头是中证系。
  final sz = code.startsWith('399') || code.startsWith('98');
  final csi = !sz && (code.startsWith('H') || code.startsWith('9'));
  if (csi) {
    add('CSI$code');
    add('SH$code');
    add('SZ$code');
  } else if (sz) {
    add('SZ$code');
    add('CSI$code');
    add('SH$code');
  } else {
    add('SH$code');
    add('CSI$code');
    add('SZ$code');
  }
  return out;
}

/// 两个来源给的指数名是不是同一个指数（宽松比对，只用于**挑更可信的那个猜测**）
///
/// 去掉空格/括号/「指数」等噪声后，相等或互相包含就算对得上 —— 实测会遇到的差异：
/// 东财叫「SSH黄金股票」、中证目录叫「中证沪深港黄金产业股票」、蛋卷可能叫
/// 「黄金股票」，**所以不能做严格相等**。
bool indexNameMatches(String a, String b) {
  String norm(String s) => s
      .replaceAll(RegExp(r'[\s（）()\[\]·、,，.\-_/]'), '')
      .replaceAll('指数', '')
      .replaceAll('全收益', '')
      .toLowerCase();
  final x = norm(a), y = norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
}

/// **实测蛋卷收录**的指数种子（2026-09-28 逐个验过能出股息率）。
///
/// ⚠️ 2026-09-29 起**页面不再拿它当入口**（用户口径：「想要的是通用模版，
/// 不针对个人偏好」→ 入口改成中证官方全量目录 3001 条，见 `index_catalog.dart`）。
/// 留着只作两用：①覆盖率测试的样本；②排"我猜的符号"对不对。
const List<({String symbol, String name})> kVerifiedIndexSymbols = [
  (symbol: 'SH000922', name: '中证红利'),
  (symbol: 'CSIH30269', name: '红利低波'),
  (symbol: 'SH000015', name: '上证红利'),
  (symbol: 'CSI930740', name: '300红利LV'),
  (symbol: 'SH000300', name: '沪深300'),
  (symbol: 'SH000905', name: '中证500'),
  (symbol: 'SZ399006', name: '创业板'),
  (symbol: 'SZ399324', name: '深证红利'),
];
