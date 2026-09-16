/// 场外基金 → 关联 ETF 的猜测规则
///
/// 场外基金没有实时行情（实测 021362 / 025497 的估值字段都是空的），所以调仓时
/// 用它所跟踪的那只场内 ETF 的实时涨幅来估：**场外基金 ≈ 关联 ETF × 95%**。
///
/// 关联关系怎么来的：先在基础数据库/联网搜索里按名字找候选 ETF，再打分选最好的。
/// 打分**公司名优先**——「易方达国证价值100ETF联接发起式A」应该配「价值ETF易方达」
/// 而不是同指数的「价值ETF鹏华」；公司配不上时再比名字的最长公共子串，
/// 「易方达黄金股指数发起式A」在几家黄金股 ETF 里任选一只都行，因为跟踪的是同一个指数。
///
/// 猜错不要紧：调仓卡片上会写明用的是哪只 ETF，并且可以手动改。
library;

/// 名称里的干扰词，从长到短依次剥离
const List<String> _suffixes = [
  '联接发起式',
  '发起式',
  'ETF联接',
  '指数增强',
  '增强指数',
  '联接',
  '指数',
  '增强',
  'LOF',
  'QDII',
  'ETF',
  '股票',
  '混合',
  '债券',
  '基金',
];

/// 是否是场内 ETF/LOF 代码（沪市 5xxxxx、深市 15xxxx / 16xxxx）
///
/// 场外基金都是 0 开头（00xxxx / 01xxxx / 02xxxx），用它把搜索结果里的场外基金滤掉：
/// 东财的搜索接口把场外基金也标成「基金」，只看类型区分不开。
bool isExchangeEtfCode(String code) {
  final c = code.trim();
  if (c.length != 6) return false;
  return c.startsWith('5') || c.startsWith('15') || c.startsWith('16');
}

String _normalize(String name) {
  var s = name.replaceAll(RegExp(r'[（(【\[].*?[)）】\]]'), '');
  s = s.replaceAll(RegExp(r'\s+'), '');
  // 去掉份额字母（A/C/E/I/D/O/H/R…），可能连着好几个
  s = s.replaceAll(RegExp(r'[A-Za-z]+$'), '');
  return s;
}

/// 剥掉「份额字母 + 『联接发起式』『指数』『ETF』这类后缀」后的主名
///
/// `易方达国证价值100ETF联接发起式A` → `易方达国证价值100`
/// `易方达黄金股指数发起式A` → `易方达黄金股`
String fundCoreName(String fundName) {
  var s = _normalize(fundName);
  var changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    for (final suf in _suffixes) {
      if (s.length > suf.length && s.endsWith(suf)) {
        s = s.substring(0, s.length - suf.length);
        changed = true;
        break;
      }
    }
  }
  return s;
}

/// 搜索用的关键词，从具体到宽泛
///
/// 主名本身 + 逐个剥掉开头的基金公司简称（2/3/4 字）+ 末尾 2/3 字加「ETF」
/// （「国证价值100」→「价值ETF」，用来把那家公司的 ETF 捞进候选池）。
List<String> fundLinkKeywords(String fundName) {
  final core = fundCoreName(fundName);
  if (core.isEmpty) return const [];

  final out = <String>[];
  void add(String s) {
    if (s.length >= 2 && !out.contains(s)) out.add(s);
  }

  add(core);
  for (var cut = 2; cut <= 4; cut++) {
    if (core.length > cut + 1) add(core.substring(cut));
  }

  // 末尾汉字片段 + ETF：让「价值ETF易方达」这类不含指数全名的 ETF 也能进候选。
  // 汉字片段要**忽略末尾数字**——「易方达国证价值100」的片段是「国证价值」。
  final tail = RegExp(r'[\u4e00-\u9fa5]{2,}$')
          .firstMatch(core.replaceAll(RegExp(r'[\dA-Za-z]+$'), ''))
          ?.group(0) ??
      '';
  if (tail.length >= 3) add('${tail.substring(tail.length - 3)}ETF');
  if (tail.length >= 2) add('${tail.substring(tail.length - 2)}ETF');

  return out;
}

/// 最长公共子串长度（按字符，够用且不会误伤）
int longestCommonSubstring(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var best = 0;
  final prev = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    for (var j = 1; j <= b.length; j++) {
      if (a[i - 1] == b[j - 1]) {
        cur[j] = prev[j - 1] + 1;
        if (cur[j] > best) best = cur[j];
      }
    }
    for (var j = 0; j <= b.length; j++) {
      prev[j] = cur[j];
    }
  }
  return best;
}

/// 给候选 ETF 打分：公司名命中权重远高于名字重合度
///
/// 返回 0 表示「不像」，调用方应当放弃这只候选。
int linkEtfScore(String fundName, String etfName) {
  final f = fundCoreName(fundName);
  final e = _normalize(etfName);
  if (f.isEmpty || e.isEmpty) return 0;

  var company = 0;
  for (var n = 4; n >= 2; n--) {
    if (f.length >= n && e.contains(f.substring(0, n))) {
      company = n;
      break;
    }
  }
  return company * 10 + longestCommonSubstring(f, e);
}

/// 在候选里挑最像的一只；[candidates] 是 `代码 → 名称`
///
/// 要求至少「名字有 2 个字重合」或「公司名命中」，否则返回 null（宁可留空让用户去选）。
({String code, String name, int score})? pickLinkEtf(
  String fundName,
  Map<String, String> candidates,
) {
  ({String code, String name, int score})? best;
  for (final e in candidates.entries) {
    if (!isExchangeEtfCode(e.key)) continue;
    final score = linkEtfScore(fundName, e.value);
    if (score < 2) continue;
    if (best == null || score > best.score) {
      best = (code: e.key, name: e.value, score: score);
    }
  }
  return best;
}
