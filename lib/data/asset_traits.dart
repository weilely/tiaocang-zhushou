import 'models.dart';

/// 标的类型的**能力表**：场外基金 / ETF·LOF / 股票到底哪里不一样，只在这里说清楚。
///
/// 起因（用户 2026-09-24 的问题）：「如果我持仓买的是股票或是 ETF，那么买卖与
/// 场外基金的逻辑是不是有些不一样，怎么才能兼顾两者的不同又不失统一的 UI 风格」
/// —— 答案是：**界面骨架一套，差异只落在这张表上**；之前这些判断散在
/// `roundDcaShares` / `roundPlanShares` / `fmtSharesOf` / `planNavFor` /
/// `_estChangeFor` / 持仓卡文案等 6 处以上，改一处漏一处。
///
/// **铁律：收益口径不按类型分叉。** 三种类型共用同一张 `txns` 账本、同一套平均
/// 成本法与逐日收益推导（场外用净值、场内用复权收盘价），同一笔钱必须算出同一个数。
/// 类型只影响四件事：
/// 1. 价格从哪来（场外：每天一条的净值；场内：实时行情 + 日线收盘价）
/// 2. 有没有「盘中估值」（只有场外基金有：靠关联 ETF 或自身估值推算）
/// 3. 单位与精度（份/股、两位小数/整数、一手多少）
/// 4. 分红与拆分能不能自动识别（场外靠累计净值；场内只能靠复权价/手工调整）
class AssetTraits {
  /// 单位：场外基金是「份」，场内是「股」
  final String unit;

  /// 份额是否按场外口径显示（固定两位小数）—— 见 `fmtSharesOf(isFund:)`
  final bool unitIsFund;

  /// 一手是多少：场内（ETF/股票）按手买卖，A 股与场内基金都是 100
  final int lotSize;

  /// 价格是不是**实时**的：场内行情秒级更新，场外是一天一条的净值
  final bool priceIsLive;

  /// 有没有「盘中估值」——只有场外基金有
  final bool hasEstimate;

  /// 价格那一行的标签
  final String priceLabel;

  /// 价格日期那一行的标签
  final String priceDateLabel;

  /// 买入时用户**先填哪个**：场外基金按金额申购、场内按股数下单
  final bool buyByAmount;

  const AssetTraits({
    required this.unit,
    required this.unitIsFund,
    required this.lotSize,
    required this.priceIsLive,
    required this.hasEstimate,
    required this.priceLabel,
    required this.priceDateLabel,
    required this.buyByAmount,
  });

  /// 场内（ETF/股票）共用的一份：实时价、按手、买入先填股数
  static const AssetTraits _exchange = AssetTraits(
    unit: '股',
    unitIsFund: false,
    lotSize: 100,
    priceIsLive: true,
    hasEstimate: false,
    priceLabel: '最新价',
    priceDateLabel: '行情日期',
    buyByAmount: false,
  );

  static const AssetTraits _fund = AssetTraits(
    unit: '份',
    unitIsFund: true,
    lotSize: 1,
    priceIsLive: false,
    hasEstimate: true,
    priceLabel: '最新净值',
    priceDateLabel: '净值日期',
    buyByAmount: true,
  );

  /// ETF/LOF 是**场内基金**：按手买卖、有实时价，但单位习惯上还是说「份」
  static const AssetTraits _etf = AssetTraits(
    unit: '份',
    unitIsFund: false,
    lotSize: 100,
    priceIsLive: true,
    hasEstimate: false,
    priceLabel: '最新价',
    priceDateLabel: '行情日期',
    buyByAmount: false,
  );

  /// 指数（基准线用，不进持仓）：有实时点位与日线，单位是「点」
  static const AssetTraits _index = AssetTraits(
    unit: '点',
    unitIsFund: false,
    lotSize: 1,
    priceIsLive: true,
    hasEstimate: false,
    priceLabel: '最新点位',
    priceDateLabel: '行情日期',
    buyByAmount: false,
  );

  static AssetTraits of(AssetKind kind) => switch (kind) {
        AssetKind.fund => _fund,
        AssetKind.etf => _etf,
        AssetKind.stock => _exchange,
        AssetKind.other => _index,
      };
}

/// 便捷入口：`p.asset.kind.traits` / `AssetKind.stock.traits`
extension AssetKindTraits on AssetKind {
  AssetTraits get traits => AssetTraits.of(this);
}
