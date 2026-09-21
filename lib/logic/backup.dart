import 'dart:convert';

import '../data/dca_models.dart';
import '../data/models.dart';
import '../data/nav_models.dart';

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

/// 全局备份：账户 + 标的（含分类）+ 交易流水 + **现金流水** + 再平衡目标 + 设置
/// + 关注列表 + 定投计划 + **金融基础数据** + **历史净值**
///
/// 行情缓存（quotes）刻意不备份——它是可随时重新抓取的临期数据，
/// 备份它只会让文件变大且可能过期。
///
/// `cash_txns` 从 **v2** 起进入备份：买入/卖出/分红/定投都会联动写一条现金流水，
/// 不备份它的话，恢复后交易回来了、现金账本却是空的，余额与交易对不上。
///
/// `securities`（金融基础数据：基金/股票名录）与 `nav_history`（历史净值）
/// 从 **v4** 起进入备份 —— 用户要求「备份改为全局备份，包括金融基础数据、历史净值」。
/// 它们都是**可重抓但要花很久**的数据（净值要一只只补、基础数据要下全量），
/// 所以值得进备份；存的是**原样的表行**（列名与建表语句一致），恢复时直接入表。
/// 老备份（v1~v3）没有这两段，解码时按空处理、恢复时**不动**这两张表。
class AppBackup {
  static const String appTag = 'invest_tracker';

  /// v1：账户/标的/流水/目标/设置；v2：现金流水；v3：关注列表与定投计划；
  /// v4：金融基础数据（securities）与历史净值（nav_history）
  static const int currentVersion = 4;

  final int version;
  final DateTime exportedAt;
  final List<Account> accounts;
  final List<Asset> assets;
  final List<Txn> txns;
  final List<CashTxn> cashTxns;
  final List<TargetAlloc> targets;
  final Map<String, String> settings;
  final List<WatchItem> watchlist;
  final List<DcaPlan> dcaPlans;

  /// 金融基础数据的表行（列名同 `securities` 建表语句）
  final List<Map<String, Object?>> securities;

  /// 历史净值的表行（列名同 `nav_history` 建表语句）
  final List<Map<String, Object?>> navHistory;

  AppBackup({
    this.version = currentVersion,
    required this.exportedAt,
    required this.accounts,
    required this.assets,
    required this.txns,
    this.cashTxns = const [],
    required this.targets,
    required this.settings,
    this.watchlist = const [],
    this.dcaPlans = const [],
    this.securities = const [],
    this.navHistory = const [],
  });

  int get accountCount => accounts.length;

  int get navHistoryCount => navHistory.length;

  /// 有交易记录的标的数
  int get usedAssetCount {
    final ids = txns.map((t) => t.assetId).toSet();
    return assets.where((a) => ids.contains(a.id)).length;
  }

  Map<String, Object?> toJson() => {
        'app': appTag,
        'version': version,
        'exportedAt': exportedAt.millisecondsSinceEpoch,
        'accounts': accounts.map((e) => e.toMap()).toList(),
        'assets': assets.map((e) => e.toMap()).toList(),
        'txns': txns.map((e) => e.toMap()).toList(),
        'cashTxns': cashTxns.map((e) => e.toMap()).toList(),
        'targets': targets.map((e) => e.toMap()).toList(),
        'watchlist': watchlist.map((e) => e.toMap()).toList(),
        'dcaPlans': dcaPlans.map((e) => e.toMap()).toList(),
        'settings': settings,
        // 这两段行数很多（历史净值可能几万行），**不加缩进** ——
        // 否则文件会大出好几倍，而它们本来就是给程序读的
        'securities': securities,
        'navHistory': navHistory,
      };

  /// 顶层保持缩进（便于人看），但两个大表用紧凑写法
  String encode() {
    final map = toJson();
    final big = {
      'securities': jsonEncode(map.remove('securities')),
      'navHistory': jsonEncode(map.remove('navHistory')),
    };
    var text = const JsonEncoder.withIndent('  ').convert(map);
    // 把紧凑的大表塞回顶层（去掉原 JSON 的收尾大括号再补上）
    final trimmed = text.trimRight();
    assert(trimmed.endsWith('}'));
    final head = trimmed.substring(0, trimmed.length - 1).trimRight();
    final sep = head.endsWith('{') ? '' : ',';
    final buf = StringBuffer()
      ..write(head)
      ..write(sep)
      ..write('\n  "securities": ')
      ..write(big['securities'])
      ..write(',\n  "navHistory": ')
      ..write(big['navHistory'])
      ..write('\n}');
    return buf.toString();
  }

  static AppBackup decode(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw BackupException('文件内容为空');
    }
    dynamic raw;
    try {
      raw = jsonDecode(trimmed);
    } catch (e) {
      throw BackupException('不是合法的 JSON 文件：$e');
    }
    if (raw is! Map) {
      throw BackupException('备份文件格式不正确（根节点应为对象）');
    }
    final map = Map<String, dynamic>.from(raw);

    if (map['app'] != appTag) {
      throw BackupException('这不是「投资记账本」的备份文件');
    }
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version > currentVersion) {
      throw BackupException('备份文件版本（v$version）高于当前应用支持的版本（v$currentVersion），请先升级应用');
    }

    return AppBackup(
      version: version,
      exportedAt: DateTime.fromMillisecondsSinceEpoch(
          (map['exportedAt'] as num?)?.toInt() ?? 0),
      accounts: _list(map['accounts']).map(Account.fromMap).toList(),
      assets: _list(map['assets']).map(Asset.fromMap).toList(),
      txns: _list(map['txns']).map(Txn.fromMap).toList(),
      // v1 备份没有这一段，按空处理而不是报错
      cashTxns: _list(map['cashTxns']).map(CashTxn.fromMap).toList(),
      targets: _list(map['targets']).map(TargetAlloc.fromMap).toList(),
      // v1/v2 备份没有这两段，按空处理而不是报错
      watchlist: _list(map['watchlist']).map(WatchItem.fromMap).toList(),
      dcaPlans: _list(map['dcaPlans']).map(DcaPlan.fromMap).toList(),
      settings: _stringMap(map['settings']),
      // v4 起才有；老备份为空 → 恢复时不动这两张表
      securities: _list(map['securities']),
      navHistory: _list(map['navHistory']),
    );
  }

  static List<Map<String, Object?>> _list(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, Object?>.from(e))
        .toList();
  }

  static Map<String, String> _stringMap(dynamic v) {
    if (v is! Map) return const {};
    final out = <String, String>{};
    v.forEach((k, val) {
      if (val != null) out[k.toString()] = val.toString();
    });
    return out;
  }
}
