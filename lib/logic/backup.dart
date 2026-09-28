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
/// + 关注列表 + 定投计划 + **金融基础数据** + **历史净值** + **宏观估值历史**
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
///
/// `macro_history`（股债利差每日一点，`macroRows`）是 v4 之后**纯新增**的一段：
/// 它同样是「本地一天一点攒出来的历史」，丢了要等下次联网回填 10 年。
/// 老版本读到会忽略这个字段，新版本读到老 v4 备份时它为空（恢复时不动本表），
/// 所以**不抬备份版本号**（与 targets 的 `account_id` 同一个先例）。
/// 密钥类设置（目前只有同花顺的 API Key）
///
/// **2026-09-28 起语义变了**：用户要求「同花顺的 key … **一同备份**」，
/// 所以导出时**不再剔除**它（备份文件里会有明文 Key，自己留着别外传）；
/// 这个清单现在只剩一个用途 —— **恢复时兜底**：
/// 老备份（在 Key 进备份之前导出的）里没有这把 Key，
/// 那就**保留本机原有的**，别把用户刚填好的 Key 抹掉（见 [secretsToKeep]）。
const List<String> kSecretSettingKeys = ['hithinkApiKey'];

/// 导出时写进备份的设置项：**整张表都写**（含密钥类）
Map<String, String> settingsForBackup(Map<String, String> all) => Map.of(all);

/// 恢复时要从**本机**保留（而不是被备份覆盖/清空）的密钥类设置：
/// 只保留「备份里压根没有这把 Key」的那些（老备份兼容）
Map<String, String> secretsToKeep({
  required Map<String, String> local,
  required Map<String, String> fromBackup,
}) =>
    {
      for (final k in kSecretSettingKeys)
        if (!fromBackup.containsKey(k) && (local[k] ?? '').isNotEmpty)
          k: local[k]!,
    };

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

  /// 宏观估值（股债利差）每日点的表行（列名同 `macro_history` 建表语句）
  ///
  /// 为什么值得备份：这张表是**本地一天一点攒出来的历史**（回填能补齐 10 年，
  /// 但要联网、要等接口通）。用户看的是「当前利差在历史多少分位」，
  /// 恢复后若这段空着，宏观卡片就只有今天一个点。
  final List<Map<String, Object?>> macroRows;

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
    this.macroRows = const [],
  });

  int get accountCount => accounts.length;

  int get navHistoryCount => navHistory.length;

  /// 宏观估值（股债利差）历史点数
  int get macroRowCount => macroRows.length;

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
        // 每条目标带 account_id（调仓目标按账户分开存）；老备份没这列，
        // 解码时统一归到第一个账户（见 TargetAlloc.fromMap）。
        // 纯新增字段：老版本读到会忽略，所以**不抬备份版本号**
        'targets': targets.map((e) => e.toMap()).toList(),
        'watchlist': watchlist.map((e) => e.toMap()).toList(),
        'dcaPlans': dcaPlans.map((e) => e.toMap()).toList(),
        'settings': settings,
        // 这几段行数很多（历史净值可能几万行、基础数据三万多行），**不加缩进** ——
        // 否则文件会大出好几倍，而它们本来就是给程序读的
        'securities': securities,
        'navHistory': navHistory,
        'macroHistory': macroRows,
      };

  /// 备份里的账户 id（升序）；恢复时给「没有账户归属的老目标」找家
  List<int> get accountIds => [
        for (final a in accounts)
          if (a.id != null) a.id!,
      ]..sort();

  /// 顶层保持缩进（便于人看），但行数多的几段用紧凑写法
  String encode() {
    final map = toJson();
    // 顺序 = 写进文件里的顺序；都是「表行」性质，一行一条、只给程序读
    const compactKeys = ['securities', 'navHistory', 'macroHistory'];
    final compact = <String, String>{
      for (final k in compactKeys) k: jsonEncode(map.remove(k) ?? const []),
    };
    var text = const JsonEncoder.withIndent('  ').convert(map);
    // 把紧凑的大表塞回顶层（去掉原 JSON 的收尾大括号再补上）
    final trimmed = text.trimRight();
    assert(trimmed.endsWith('}'));
    final head = trimmed.substring(0, trimmed.length - 1).trimRight();
    var sep = head.endsWith('{') ? '' : ',';
    final buf = StringBuffer()..write(head);
    for (final k in compactKeys) {
      buf.write(sep);
      buf.write('\n  "$k": ');
      buf.write(compact[k]);
      sep = ',';
    }
    buf.write('\n}');
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
      // v4 之后新增的一段；老备份为空 → 恢复时不动 macro_history
      macroRows: _list(map['macroHistory']),
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
