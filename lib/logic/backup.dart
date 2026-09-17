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

/// 完整数据备份：账户 + 标的（含分类）+ 交易流水 + **现金流水** + 再平衡目标 + 设置
///
/// 行情缓存（quotes）刻意不备份——它是可随时重新抓取的临期数据，
/// 备份它只会让文件变大且可能过期。
///
/// `cash_txns` 从 **v2** 起进入备份：买入/卖出/分红/定投都会联动写一条现金流水，
/// 不备份它的话，恢复后交易回来了、现金账本却是空的，余额与交易对不上。
class AppBackup {
  static const String appTag = 'invest_tracker';

  /// v1：账户/标的/流水/目标/设置；v2：增加现金流水；v3：增加关注列表与定投计划
  static const int currentVersion = 3;

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
  });

  int get accountCount => accounts.length;

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
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

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
