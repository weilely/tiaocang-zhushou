// 同花顺「基金详情」三接口的**真凭证探针**（不联网跑测试时用）。
//
// 为什么要有它：文档站的字段与实测有三处不符，而单测只能钉住"我以为的契约"。
// 改了这一路（`lib/data/fund_detail.dart` / `lib/data/hithink_api.dart`）之后，
// 拿真 Key 跑一次，确认字段名与量级没变。
//
// 用法（Key 不落进仓库，从文件或环境变量取）：
//   dart run tool/probe_fund_detail.dart 021362            # 场外基金 → 021362.OF
//   dart run tool/probe_fund_detail.dart 510300 --etf      # 场内 → 510300.SH
//   HITHINK_KEY=xxx dart run tool/probe_fund_detail.dart 021362
//
// 默认从 `E:\DSH\.hithink_key.txt`（工作区根、不在仓库内）读 Key。
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:invest_tracker/data/fund_detail.dart';
import 'package:invest_tracker/data/hithink_api.dart';

Future<void> main(List<String> args) async {
  final code = args.isNotEmpty && !args.first.startsWith('--')
      ? args.first
      : '021362';
  final otc = !args.contains('--etf');

  final key = _apiKey();
  if (key.isEmpty) {
    stderr.writeln('没找到 API Key：传 HITHINK_KEY 环境变量，'
        '或放到 E:\\DSH\\.hithink_key.txt');
    exit(2);
  }

  final thscode = HithinkApi.fundThscodeFor(code, otc: otc);
  final out = StringBuffer('thscode = $thscode\n');

  final api = HithinkApi(http.Client());
  final paths = {
    'profile': '/api/fund/profile/detail',
    'holdings': '/api/fund/portfolio/holdings',
    'dividends': '/api/fund/corporate-actions/dividends',
  };

  Map<String, dynamic>? profileJson;
  Map<String, dynamic>? holdingsJson;
  Map<String, dynamic>? dividendsJson;
  final rawAll = <String, dynamic>{};
  for (final e in paths.entries) {
    try {
      final j = await api.fundDetail(e.value, thscode!, key);
      rawAll[e.key] = j;
      out.writeln('--- ${e.key} OK: ${jsonEncode(j).length} 字符');
      switch (e.key) {
        case 'profile':
          profileJson = j;
        case 'holdings':
          holdingsJson = j;
        case 'dividends':
          dividendsJson = j;
      }
    } catch (err) {
      out.writeln('--- ${e.key} FAIL: $err');
    }
  }

  // 原始响应留一份（按需看字段名，别猜）
  File(r'E:\DSH\fund_detail_probe_raw.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rawAll));

  // 档案里每条 rate_info 的**原始键值**：费率字段实测与本项目文档不一致，
  // 遇到想看的字段没解析出来时，看这里而不是改代码猜
  final firstItemList = profileJson?['data']?['item'];
  final firstItem =
      (firstItemList is List && firstItemList.isNotEmpty) ? firstItemList.first : null;
  if (firstItem is Map) {
    out.writeln('\n[档案原始] item[0] 的键 = ${(firstItem.keys).join(',')}');
    final rates = firstItem['rate_info'];
    if (rates is List) {
      for (final r in rates.take(3)) {
        out.writeln('  rate_info 原始 = ${jsonEncode(r)}');
      }
    }
  }

  if (profileJson != null) {
    final p = FundProfile.fromJson(profileJson);
    out
      ..writeln('\n[档案] ticker=${p.ticker} 公司=${p.companyName} '
          '成立=${p.estabDate} 规模=${p.scale} 净值=${p.unitNav} '
          '经理=${p.managers.map((m) => '${m.name}(${m.tenureDays}天/'
              '${m.tenureReturnPct}%)').join(',')}')
      ..writeln('  交易规则=${p.tradeRules.map((r) => '${r.title}:${r.displayTime}').join(' | ')}')
      ..writeln('  费率=${p.rates.map((r) => '${r.condition} ${r.standardRate}->${r.discountedRate}').join(' | ')}');
  }

  if (holdingsJson != null) {
    final pf = FundPortfolio.fromJson(holdingsJson);
    out.writeln('\n[持仓] 股票占净值=${pf.stockRatioPct} 行业=${pf.mainIndustry} '
        '集中度=${pf.concentrationRatio} 报告期=${pf.publishDate}');
    for (final h in pf.holdings.take(10)) {
      out.writeln('  ${h.rank} ${h.name} ${h.ticker} 占净值=${h.holdRatio}% '
          '市值=${h.positionCapital}');
    }
  }

  if (dividendsJson != null) {
    final d = FundDividends.fromJson(dividendsJson);
    out.writeln('\n[分红] count=${d.count} total=${d.total} '
        'confirmedEmpty=${d.confirmedEmpty} items=${d.items.length}');
    for (final it in d.items.take(5)) {
      out.writeln('  除息=${it.exDividendDate} 每10份税前=${it.perTenBeforeTax} '
          '税后=${it.perTenAfterTax} 进度=${it.progress}');
    }
  }

  api.dispose();
  final path = r'E:\DSH\fund_detail_probe.txt';
  File(path).writeAsStringSync(out.toString(), encoding: utf8);
  stdout.writeln('写到 $path');
}

String _apiKey() {
  final env = Platform.environment['HITHINK_KEY'];
  if (env != null && env.trim().isNotEmpty) return env.trim();
  final f = File(r'E:\DSH\.hithink_key.txt');
  return f.existsSync() ? f.readAsStringSync().trim() : '';
}
