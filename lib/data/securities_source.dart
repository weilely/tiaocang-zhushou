import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/pinyin_util.dart';
import 'market_api.dart';
import 'securities_repo.dart';

/// 场内基金代码前缀（沪 50/51/52/56/58，深 15/16）
const Set<String> _exchangeFundPrefix = {'15', '16', '50', '51', '52', '56', '58'};

/// 股票代码前三位 → 板块（56 页全量实测覆盖 5,561 条，无遗漏）
const Map<String, String> stockBoardByPrefix = {
  '600': '上证',
  '601': '上证',
  '603': '上证',
  '605': '上证',
  '000': '深证',
  '001': '深证',
  '002': '深证',
  '003': '深证',
  '300': '创业',
  '301': '创业',
  '302': '创业',
  '688': '科创',
  '920': '北证',
};

/// 板块 → 默认可用的资产大类（用于再平衡）
const Map<String, String> boardAssetCategory = {
  '上证': '股票',
  '深证': '股票',
  '创业': '股票',
  '科创': '股票',
  '北证': '股票',
};

/// 基金一级类型 → 默认可用的资产大类（用于再平衡）
const Map<String, String> fundClassAssetCategory = {
  '股票型': '股票',
  '指数型': '股票',
  '混合型': '混合',
  'FOF': '混合',
  '债券型': '债券',
  '货币型': '现金',
  'QDII': '海外',
  '商品': '另类',
  'Reits': '另类',
};

/// 由基础数据库记录推断资产大类（再平衡用），无对应返回空串
String assetCategoryFor(SecurityRow row) {
  if (row.secClass == '股票') {
    return boardAssetCategory[row.secSub] ?? '股票';
  }
  return fundClassAssetCategory[row.secClass] ?? '';
}

/// 由股票代码推断板块（三位表优先，兜底按前缀）
String boardOf(String code) {
  if (code.length >= 3) {
    final byThree = stockBoardByPrefix[code.substring(0, 3)];
    if (byThree != null) return byThree;
  }
  if (code.startsWith('68')) return '科创';
  if (code.startsWith('30')) return '创业';
  if (code.startsWith('92') || code.startsWith('8')) return '北证';
  if (code.startsWith('6') || code.startsWith('9')) return '上证';
  if (code.startsWith('0') || code.startsWith('2')) return '深证';
  return '其他';
}

/// 由交易所前缀推断市场
String marketOfSymbol(String symbol) {
  switch (symbol.toLowerCase()) {
    case 'sh':
      return 'SH';
    case 'sz':
      return 'SZ';
    case 'bj':
      return 'BJ';
    default:
      return '';
  }
}

class StockPageResult {
  final List<SecurityRow> rows;

  /// 服务端报告的总条数
  final int total;
  const StockPageResult({required this.rows, required this.total});

  int get totalPages => total <= 0 ? 1 : (total + 99) ~/ 100;
}

class SecuritiesUpdateException implements Exception {
  final String message;
  SecuritiesUpdateException(this.message);
  @override
  String toString() => message;
}

/// 基础数据库的下载源
///
/// - 基金：[fundcode_search.js] 单请求 3 MB，27,845 条，**自带首拼与全拼**
/// - 股票：新浪行情中心分页，每页上限 100，首拼由本地字典生成
///
/// 刻意不使用东财 `push2/clist` —— 该端点对连续请求会持续返回 502。
class SecuritiesSource {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 12; AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  SecuritiesSource([http.Client? client]) : _client = client ?? http.Client();

  void dispose() => _client.close();

  Future<http.Response> _get(Uri uri, {Duration timeout = const Duration(seconds: 60)}) async {
    try {
      return await _client.get(uri, headers: {
        'User-Agent': _ua,
        'Referer': 'https://fund.eastmoney.com/',
      }).timeout(timeout);
    } on Exception catch (e) {
      throw SecuritiesUpdateException('网络请求失败：$e');
    }
  }

  // ---------------- 基金全量 ----------------

  static final RegExp _fundRowPattern =
      RegExp(r'\["(\d{6})","([^"]*)","([^"]*)","([^"]*)","([^"]*)"\]');

  /// 拉取全量基金列表（含 ETF / LOF）
  Future<List<SecurityRow>> fetchFundList() async {
    final res = await _get(Uri.parse('http://fund.eastmoney.com/js/fundcode_search.js'));
    if (res.statusCode != 200) {
      throw SecuritiesUpdateException('基金列表下载失败：HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    final now = DateTime.now().millisecondsSinceEpoch;

    final rows = <SecurityRow>[];
    for (final m in _fundRowPattern.allMatches(text)) {
      rows.add(_fundRow(
        code: m.group(1)!,
        pinyin: m.group(2)!,
        name: m.group(3)!,
        type: m.group(4)!,
        fullPinyin: m.group(5)!,
        now: now,
      ));
    }
    if (rows.isEmpty) {
      throw SecuritiesUpdateException('基金列表解析结果为空（接口格式可能已变更）');
    }
    return rows;
  }

  static SecurityRow _fundRow({
    required String code,
    required String pinyin,
    required String name,
    required String type,
    required String fullPinyin,
    required int now,
  }) {
    final prefix = code.substring(0, 2);
    final isExchange = _exchangeFundPrefix.contains(prefix);
    final cleanName = name.trim();
    final cleanType = type.trim();

    String cls;
    String sub;
    final dash = cleanType.indexOf('-');
    if (cleanType.isEmpty) {
      cls = '未分类';
      sub = '';
    } else if (dash > 0) {
      cls = cleanType.substring(0, dash);
      sub = cleanType.substring(dash + 1);
    } else {
      cls = cleanType;
      sub = '';
    }

    final py = pinyin.trim();
    final full = fullPinyin.trim();

    return SecurityRow(
      code: code,
      kind: isExchange ? 'etf' : 'fund',
      name: cleanName,
      // 官方给的缩写最准（名字里带 ETF/300 这种数字字母时也一样），缺失才本地生成
      pinyin: py.isNotEmpty ? py.toUpperCase() : pinyinInitials(cleanName),
      fullPinyin: full.isNotEmpty ? full.toLowerCase() : fullPinyinOf(cleanName),
      secType: cleanType.isEmpty ? '未分类' : cleanType,
      secClass: cls,
      secSub: sub,
      market: isExchange ? (code.startsWith('5') ? 'SH' : 'SZ') : '',
      source: 'fund_list',
      updatedAt: now,
    );
  }

  // ---------------- A 股分页 ----------------

  /// 拉取一页 A 股（新浪按 symbol 升序，`bj` → `sh` → `sz`）
  Future<StockPageResult> fetchStockPage(int page, {int num = 100}) async {
    final uri = Uri.parse(
      'http://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/'
      'Market_Center.getHQNodeData?page=$page&num=$num&sort=symbol&asc=1'
      '&node=hs_a&symbol=&_s_r_a=page',
    );
    final res = await _get(uri, timeout: const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw SecuritiesUpdateException('第 $page 页下载失败：HTTP ${res.statusCode}');
    }

    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (text.trim().isEmpty) return const StockPageResult(rows: [], total: 0);

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw SecuritiesUpdateException('第 $page 页解析失败：$e');
    }
    if (decoded is! List) {
      throw SecuritiesUpdateException('第 $page 页返回格式异常');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = <SecurityRow>[];
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final symbol = (raw['symbol'] ?? '').toString();
      final code = (raw['code'] ?? '').toString();
      final name = (raw['name'] ?? '').toString().trim();
      if (code.length != 6 || name.isEmpty) continue;

      final ex = symbol.replaceAll(RegExp(r'\d+$'), '');
      final board = boardOf(code);
      rows.add(SecurityRow(
        code: code,
        kind: 'stock',
        name: name,
        pinyin: pinyinInitials(name),
        fullPinyin: fullPinyinOf(name),
        secType: '股票-$board',
        secClass: '股票',
        secSub: board,
        market: marketOfSymbol(ex),
        source: 'sina',
        updatedAt: now,
      ));
    }

    // 总数从首页的 Content-Range 拿不到，用 total 接口单独取；这里先按页推断
    return StockPageResult(rows: rows, total: 0);
  }

  /// A 股总数（新浪单独提供）
  Future<int> fetchStockTotal() async {
    final res = await _get(
      Uri.parse(
        'http://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/'
        'Market_Center.getHQNodeStockCount?node=hs_a',
      ),
      timeout: const Duration(seconds: 20),
    );
    if (res.statusCode != 200) {
      throw SecuritiesUpdateException('获取股票总数失败：HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    return int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  /// 按代码查一条（远程兜底时用，返回 null 表示查不到）
  static SecurityRow? remoteRowFrom({
    required String code,
    required String name,
    required String kind,
    required String market,
    required String pinyin,
  }) =>
      SecurityRow(
        code: code,
        kind: kind,
        name: name,
        pinyin: pinyin.isNotEmpty ? pinyin.toUpperCase() : pinyinInitials(name),
        fullPinyin: fullPinyinOf(name),
        secType: kind == 'stock' ? '股票-${boardOf(code)}' : '',
        secClass: kind == 'stock' ? '股票' : '',
        secSub: kind == 'stock' ? boardOf(code) : '',
        market: market,
        source: 'remote',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// 供上层判断网络层错误
  static String describeError(Object e) =>
      e is MarketException ? e.message : e.toString();
}
