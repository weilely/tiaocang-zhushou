import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/asset_traits.dart';
import '../data/market_api.dart';
import '../data/models.dart';
import '../data/securities_repo.dart';
import '../data/securities_source.dart';
import '../logic/nav_lookup.dart';
import '../logic/redeem_fee.dart';
import '../logic/txn_form.dart';
import '../state/app_state.dart';
import 'redeem_fee_sheet.dart';
import 'widgets/cn_date_picker.dart';

class TxnEditPage extends StatefulWidget {
  final Txn? existing;

  /// 从持仓详情页进入时锁定账户与标的（隐藏搜索框，改只读展示）
  final Asset? presetAsset;
  final int? presetAccountId;

  /// 预设交易类型（买入 / 卖出 / 分红）
  final TxnType? presetType;

  /// 预设备注（例如 `定投`、`期初持仓`）
  final String? presetNote;

  /// 卖出时用于校验的最大可卖份额
  final double? maxShares;

  const TxnEditPage({
    super.key,
    this.existing,
    this.presetAsset,
    this.presetAccountId,
    this.presetType,
    this.presetNote,
    this.maxShares,
  });

  @override
  State<TxnEditPage> createState() => _TxnEditPageState();
}

class _TxnEditPageState extends State<TxnEditPage> {
  final _formKey = GlobalKey<FormState>();

  TxnType _type = TxnType.buy;
  int? _accountId;
  int? _assetId;
  AssetKind _kind = AssetKind.fund;
  DateTime _date = DateTime.now();

  final _code = TextEditingController();
  final _name = TextEditingController();
  final _shares = TextEditingController();
  final _price = TextEditingController();
  final _amount = TextEditingController();
  final _fee = TextEditingController();
  final _note = TextEditingController();

  /// 佣金费率输入框（万分之几，按账户存）
  final _feeRateCtrl = TextEditingController();

  /// 「待确认」：场外基金当天净值还没公布时，先只记金额、份额留空，
  /// 等净值公布后由 `AppState.fillPendingTxns()` 自动补（用户 2026-09-28 选的做法）
  bool _pending = false;

  /// 打开编辑页那一刻的表单快照：没有任何改动时「保存」置灰
  /// （用户 2026-09-29：「数据没有改动保存就不能用」）
  late String _initialSnapshot;

  /// 场外**卖出**用的赎回档位（异步从基金档案取；取到前先按内置默认档估）
  List<RedeemTier> _redeemTiers = kDefaultRedeemTiers;
  String _tiersSource = '';
  bool _tiersLoaded = false;

  /// 用户有没有手改过「手续费（实际）」：没改过才跟着 FIFO 估算自动走
  bool _feeTouched = false;

  bool _autoAmount = false;
  bool _autoShares = true;

  /// 程序化写控制器期间为 true：避免把「自动填入」误判成用户手改
  bool _writing = false;

  /// 代码框里是否已有内容
  bool _navHasTarget = false;

  /// 最近一次查询针对的「代码|日期」；与当前输入不一致时提示行回到中性文案
  String? _navQueriedKey;

  bool get _navQueried =>
      _navQueriedKey == '${_code.text.trim()}|${fmtDate(_date)}';

  /// 按日期查净值的状态
  NavFill? _navFill;
  bool _navBusy = false;
  String? _navError;

  /// 代数计数器：日期被连续改动时丢弃过期响应
  int _navGen = 0;

  /// 账户与标的已锁定（从持仓详情页进入）
  bool _locked = false;

  /// 选中的资产大类（从搜索结果带出的默认值，可被用户改写）
  String _category = '';

  // ---- 搜索基础数据库 ----
  Timer? _debounce;
  List<SecurityRow> _results = const [];
  bool _searching = false;
  bool _showResults = false;
  bool _fromRemote = false;
  String? _searchError;
  String? _clsFilter;
  String? _subFilter;

  @override
  void initState() {
    super.initState();
    final st = context.read<AppState>();
    final e = widget.existing;

    if (e != null) {
      _type = e.type;
      _accountId = e.accountId;
      _assetId = e.assetId;
      final a = st.assetsById[e.assetId];
      if (a != null) {
        _kind = a.kind;
        _code.text = a.code;
        _name.text = a.name;
        _category = a.category;
      }
      _shares.text = _trim(e.shares);
      _price.text = _trim(e.price);
      _amount.text = _trim(e.amount);
      _fee.text = _trim(e.fee);
      _note.text = e.note;
      _date = e.date;
      _navHasTarget = _code.text.trim().isNotEmpty;
      // 编辑既有记录：打开时一个字段都不动，改哪个哪个说了算
      _autoAmount = false;
      _autoShares = false;
      // 「待确认」是**记账当时**的选择，编辑时照原样带出来
      // （用户 2026-09-29：编辑页里不该出现「改为待确认」这个开关）
      _pending = e.pending;
    } else {
      _accountId = widget.presetAccountId ??
          st.accountFilter ??
          (st.accounts.isNotEmpty ? st.accounts.first.id : null);

      // 从持仓详情页进入：账户与标的锁定
      final pa = widget.presetAsset;
      if (pa != null) {
        _assetId = pa.id;
        _kind = pa.kind;
        _code.text = pa.code;
        _name.text = pa.name;
        _category = pa.category;
        _locked = true;
        _navHasTarget = true;
      }
      if (widget.presetType != null) _type = widget.presetType!;
      if (widget.presetNote != null) _note.text = widget.presetNote!;
      // 卖出时默认带上全部可卖份额
      if (widget.presetType == TxnType.sell && (widget.maxShares ?? 0) > 0) {
        _shares.text = _trim(widget.maxShares!);
      }
      _resetDerivedFlag();
    }

    _shares.addListener(_onSharesChanged);
    _price.addListener(_onPriceChanged);
    _amount.addListener(_onAmountChanged);
    // 费率框按当前「标的类型 + 交易类型」载入：场内→账户佣金率，场外→该基金的申购/赎回费率
    _reloadFeeRate();
    // 「实际」手续费默认为 0（用户要求）；编辑既有流水则沿用记录里的值
    if (widget.existing == null) _fee.text = '0';

    // 记下"刚打开时长什么样"：没有任何改动时「保存」要置灰
    // （用户 2026-09-29：「数据没有改动保存就不能用」）
    _initialSnapshot = _formSnapshot();

    // 进来就带着标的（从持仓详情页）时，先按当前日期查一次净值
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 预填的场景（从详情页卖出）不会有"变更事件"，这里刷一次，
      // 让「预测」那一格按已填的金额/费率算出来
      setState(() {});
      if (widget.existing == null && _code.text.isNotEmpty) _syncNav();
      // 场外卖出：把该基金的赎回档位取回来（用户改过 → 档案 → 默认），再算预估
      unawaited(_loadRedeemTiers());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _shares.removeListener(_onSharesChanged);
    _price.removeListener(_onPriceChanged);
    _amount.removeListener(_onAmountChanged);
    for (final c in [
      _code,
      _name,
      _shares,
      _price,
      _amount,
      _fee,
      _note,
      _feeRateCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------- 金额 / 份额 / 净值的联动 ----------------

  /// 当前标的的能力表（单位、按手、实时价、买入主字段都在这里）
  AssetTraits get _traits => AssetTraits.of(_kind);

  /// 当前的主输入字段：场外基金买入=金额，场内买入=股数，卖出=份额
  PrimaryField get _primary => primaryFieldFor(_type, _traits);

  /// 主字段随交易类型与标的类型互换（场内买入先填股数）
  void _resetDerivedFlag() {
    switch (_primary) {
      case PrimaryField.amount:
        _autoShares = true;
        _autoAmount = false;
        break;
      case PrimaryField.shares:
        _autoAmount = true;
        _autoShares = false;
        break;
      case PrimaryField.none:
        _autoAmount = false;
        _autoShares = false;
        break;
    }
  }

  /// 写控制器并标记为程序化写入（监听器据此不把它当成用户手改）
  void _setText(TextEditingController c, String v) {
    if (c.text == v) return;
    _writing = true;
    c.text = v;
    _writing = false;
  }

  /// 金额变了算份额，份额变了算金额（**谁被用户改，谁就是主字段**）
  ///
  /// 场外基金买入是金额主字段、场内买入是股数主字段，所以这里按
  /// `_autoShares` / `_autoAmount` 两个开关走，不按交易类型硬判。
  void _syncDerived() {
    if (_type == TxnType.dividend) return;
    final price = double.tryParse(_price.text) ?? 0;
    if (price <= 0) return;

    if (_type == TxnType.buy) {
      if (_autoShares) {
        final amount = double.tryParse(_amount.text) ?? 0;
        final s = derivedShares(amount: amount, price: price, traits: _traits);
        if (s != null) _setText(_shares, _trim(s));
      } else if (_autoAmount) {
        // 场内买入：股数是主字段，金额跟着算（落到分）
        final shares = double.tryParse(_shares.text) ?? 0;
        final a = derivedAmount(shares: shares, price: price);
        if (a != null) _setText(_amount, _trim(double.parse(a.toStringAsFixed(2))));
      }
    } else {
      if (!_autoAmount) return;
      final shares = double.tryParse(_shares.text) ?? 0;
      final a = derivedAmount(shares: shares, price: price);
      // 金额是钱，落到分
      if (a != null) _setText(_amount, _trim(double.parse(a.toStringAsFixed(2))));
    }
  }

  // ---------------- 手续费 / 佣金费率（用户 2026-09-25 要求） ----------------

  static String _wanText(double? wan) {
    if (wan == null || wan <= 0) return '';
    var s = wan.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  void _onFeeRateChanged(String v) {
    // **即时生效**（不做防抖）：setFeeRate/setSubFeeRate 会先把值写进内存再落库，
    // 所以紧接着的预测值立刻就能按新费率算出来。
    // 场内（ETF/股票）→ 按**账户**存佣金率（万分之几）；
    // 场外（基金）→ 按**基金代码**存申购/赎回费率（%）。
    final st = context.read<AppState>();
    final pct = double.tryParse(v.trim());
    if (_feeByFund) {
      final code = _code.text.trim();
      if (code.isEmpty) return;
      unawaited(_type == TxnType.sell
          ? st.setRedeemFeeRate(code, pct)
          : st.setSubFeeRate(code, pct));
    } else if (_accountId != null) {
      unawaited(st.setFeeRate(_accountId!, pct));
    }
    setState(() {});
  }

  /// 这一格的费率是**按基金**（场外）还是**按账户**（场内）
  bool get _feeByFund => !_kind.isExchange;

  /// 按当前「标的类型 + 交易类型 + 标的/账户」把费率框里的值重新载入
  void _reloadFeeRate() {
    final st = context.read<AppState>();
    if (_feeByFund) {
      final pct = _type == TxnType.sell
          ? st.redeemFeeRateOf(_code.text.trim())
          : st.subFeeRateOf(_code.text.trim());
      _feeRateCtrl.text = _pctText(pct);
    } else {
      _feeRateCtrl.text = _wanText(st.feeRateOf(_accountId));
    }
  }

  static String _pctText(double? pct) {
    if (pct == null || pct <= 0) return '';
    var s = pct.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// **预测**手续费（只读）：场内按佣金率+税费、场外买入按申购费率、
  /// 场外卖出按**持有天数档 + 先进先出**估的赎回费；
  /// 没设费率 / 金额为空 → null（**不猜**，那一栏显示 `--`）
  double? _predictedFee() {
    if (_type == TxnType.dividend) return null;
    // 场外卖出：FIFO × 持有天数档（档位来自基金档案，拿不到用默认档）
    if (_type == TxnType.sell && !_kind.isExchange) return _fifoRedeemFee();
    final st = context.read<AppState>();
    return st.feeForTxn(
      accountId: _accountId,
      code: _code.text.trim(),
      kind: _kind,
      type: _type,
      amount: double.tryParse(_amount.text) ?? 0,
    );
  }

  /// 场外卖出的预估赎回费（按本次卖出的份额、当日净值、FIFO 批次与档位）
  double? _fifoRedeemFee() {
    final shares = double.tryParse(_shares.text.trim()) ?? 0;
    final nav = double.tryParse(_price.text.trim()) ?? 0;
    final acc = _accountId;
    final aid = _assetId;
    if (shares <= 0 || nav <= 0 || acc == null || aid == null) return null;
    return context.read<AppState>().estimateRedeemFeeFor(
          accountId: acc,
          assetId: aid,
          shares: shares,
          date: _date,
          nav: nav,
          tiers: _redeemTiers,
        );
  }

  /// 取该基金的赎回档位（用户改过 → 基金档案 → 内置默认），取到后重算预估
  Future<void> _loadRedeemTiers() async {
    if (_kind.isExchange || _type != TxnType.sell) return;
    final code = _code.text.trim();
    if (code.isEmpty) return;
    final st = context.read<AppState>();
    final r = await st.redeemTiersFor(code);
    if (!mounted) return;
    setState(() {
      _redeemTiers = r.tiers;
      _tiersSource = r.source;
      _tiersLoaded = true;
    });
    _autoFillFee();
  }

  String _redeemTiersHint() {
    if (!_tiersLoaded) return '正在取档位…';
    if (_tiersSource.startsWith('基金档案')) return '按持有天数自动算（档位来自基金档案）';
    if (_tiersSource.startsWith('你手动')) return '按持有天数自动算（档位是你设的）';
    return '按持有天数自动算（档位用内置默认）';
  }

  /// 把 FIFO 估出来的赎回费**自动填进「手续费（实际）」**（用户 2026-09-28 选的 B）
  ///
  /// 只在「场外卖出 + 用户还没手改过实际值」时同步；用户一动那个框就不再覆盖。
  void _autoFillFee() {
    if (_feeTouched) return;
    // 编辑既有记录：手续费是**这笔真实发生过的**数，打开页面或改份额都不许被
    // FIFO 估算悄悄改掉（否则一进来就"有改动"、还能一按保存把费改了）。
    // 想看估算值：点「一键导入预测值」或「赎回费档位」都还在。
    if (widget.existing != null) return;
    if (_type != TxnType.sell || _kind.isExchange) return;
    final fee = _fifoRedeemFee();
    if (fee == null) return;
    final text = fee.toStringAsFixed(2);
    if (_fee.text != text) {
      _fee.text = text;
      if (mounted) setState(() {});
    }
  }

  /// 费率框 —— 场内是「佣金费率（万分之几）」（免五圆点嵌在框里）；
  /// 场外是「申购费率（%）」/「赎回费率（%）」，**没有免五**（最低 5 元是券商佣金概念）。
  ///
  /// 用户 2026-09-28：「区分一下场内和场外的费率设置，申购，赎回，提示在框线上显示，风格统一」
  /// —— 三种情况都用同一套 InputDecoration（label 在框线上、提示在 helper 行），只是文字不同。
  Widget _feeRateField(AppState st) {
    if (_feeByFund) {
      final isSell = _type == TxnType.sell;
      // **场外卖出**：赎回费不再手填一个固定费率 —— 按**持有天数档 + 先进先出**自动估算
      // （用户 2026-09-28：参考基金档案的赎回费率、按持仓天数估费），
      // 档位从基金档案取（拿不到用默认档），「档位」按钮能看分布并改。
      if (isSell) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: '赎回费档位',
            helperText: _redeemTiersHint(),
            isDense: true,
            suffix: TextButton(
              onPressed: _accountId == null || _assetId == null
                  ? null
                  : () => showRedeemFeeSheet(
                        context,
                        accountId: _accountId!,
                        assetId: _assetId!,
                      ),
              child: const Text('档位', style: TextStyle(fontSize: 12)),
            ),
          ),
          child: Text(
            _tiersLoaded ? '按持有天数自动算' : '取档位中…',
            style: const TextStyle(fontSize: 13),
          ),
        );
      }
      return TextFormField(
        controller: _feeRateCtrl,
        decoration: const InputDecoration(
          labelText: '申购费率（%）',
          helperText: '填 0.1 = 申购费 0.1%；留空 = 不计',
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: _onFeeRateChanged,
      );
    }
    final on = st.feeWaiveMinOf(_accountId);
    final accent = Theme.of(context).colorScheme.primary;
    final idle = Theme.of(context).hintColor;
    return TextFormField(
      controller: _feeRateCtrl,
      decoration: InputDecoration(
        labelText: '佣金费率（万分之几）',
        helperText: '填 2.5 = 万2.5；点亮圆点=免五',
        isDense: true,
        suffix: Tooltip(
          message:
              on ? '免五：已开启（豁免最低 5 元佣金）' : '免五：点击开启（豁免最低 5 元佣金）',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _accountId == null
                ? null
                : () async {
                    await context
                        .read<AppState>()
                        .setFeeWaiveMin(_accountId!, !on);
                    if (mounted) setState(() {});
                  },
            child: Padding(
              padding:
                  const EdgeInsets.only(left: 6, right: 2, top: 6, bottom: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('免五',
                      style: TextStyle(fontSize: 12, color: on ? accent : idle)),
                  const SizedBox(width: 5),
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? accent : Colors.transparent,
                      border: Border.all(color: on ? accent : idle, width: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: _onFeeRateChanged,
    );
  }

  /// 「一键导入预测值」：把预测那一栏的数抄进**实际**手续费（之后可以再手改）
  void _applyPredictedFee() {
    final fee = _predictedFee();
    if (fee == null) return;
    setState(() {
      _fee.text = fee.toStringAsFixed(2);
      // 这是用户主动搬过来的 → 之后就按"手改过"对待，不再被自动估算覆盖
      _feeTouched = true;
    });
  }

  /// 「手续费（预测）」那一格：样式跟别的输入框一致，但**不可改**
  Widget _predictedFeeBox(BuildContext context, AppState st) {
    final fee = _predictedFee();
    final byFund = _feeByFund;
    final rate = byFund
        ? (_type == TxnType.sell
            ? st.redeemFeeRateOf(_code.text.trim())
            : st.subFeeRateOf(_code.text.trim()))
        : st.feeRateOf(_accountId);
    final String helper;
    if (rate == null) {
      helper = byFund
          ? (_type == TxnType.sell
              ? _redeemTiersHint()
              : '填了申购费率才有预测')
          : '填了佣金费率才有预测';
    } else if (byFund) {
      helper = _type == TxnType.sell
          ? _redeemTiersHint()
          : '按申购费 ${_pctText(rate)}%';
    } else {
      final min = _kind.isExchange && !st.feeWaiveMinOf(_accountId)
          ? '，不足 5 元按 5 元'
          : '';
      helper = '按万${_wanText(rate)}$min';
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: '手续费（预测）',
        helperText: helper,
        enabled: false, // 灰掉，表明这一格不可改
      ),
      child: Text(
        fee == null ? '--' : '¥${fee.toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  void _onSharesChanged() {
    if (_writing) return;
    // 用户手填了份额 → 这笔不再是「待确认」
    if (_pending && _shares.text.trim().isNotEmpty) _pending = false;
    if (_type == TxnType.buy) {
      if (_primary == PrimaryField.shares) {
        _autoAmount = true; // 场内买入：股数是主字段，金额跟着算
        _autoShares = false;
      } else {
        _autoShares = false; // 场外基金：份额被手改，不再自动推（金额仍是主字段）
      }
    } else {
      _autoAmount = true; // 卖出：份额是主字段，手改后金额跟着算
    }
    _syncDerived();
    setState(() {}); // 「预测」那一格要跟着金额/份额重算
  }

  void _onAmountChanged() {
    if (_writing) return;
    if (_type == TxnType.buy) {
      _autoShares = true;
      // 场外基金买入：金额本来就是主字段；场内买入在金额上动手 → 金额成为主字段
      if (_primary == PrimaryField.shares) _autoAmount = false;
    } else {
      _autoAmount = false;
    }
    _syncDerived();
    setState(() {});
  }

  void _onPriceChanged() {
    if (_writing) return;
    // 用户手填了净值 → 这笔不再是「待确认」
    if (_pending && _price.text.trim().isNotEmpty) _pending = false;
    _syncDerived();
    _autoFillFee();
    setState(() {});
  }

  // ---------------- 按交易日期查净值 ----------------

  Future<void> _syncNav() async {
    final code = _code.text.trim();
    if (_type == TxnType.dividend || code.isEmpty) return;

    final gen = ++_navGen;
    final asset = _draftAsset();
    setState(() {
      _navBusy = true;
      _navError = null;
      _navQueriedKey = '${_code.text.trim()}|${fmtDate(_date)}';
    });

    NavFillResult res;
    try {
      res = await context.read<AppState>().lookupNavFill(asset: asset, day: _date);
    } catch (e) {
      res = NavFillResult(null, '$e');
    }
    if (!mounted || gen != _navGen) return;

    final fill = res.fill;
    setState(() {
      _navBusy = false;
      _navFill = fill;
      _navError = res.error;
    });
    if (fill != null) {
      _setText(_price, _trim(fill.nav));
      _syncDerived();
      // 净值到手 → 场外卖出的赎回费可以按 FIFO 估了（自动填「实际」）
      _autoFillFee();
      // 价格是程序化写入的（`_setText` 期间监听器不动作），这里得显式刷一次，
      // 否则「预测」手续费会停在旧金额上
      if (mounted) setState(() {});
    }
  }

  /// 查询与保存共用的标的草稿
  ///
  /// 字段一律取表单当前值（编辑交易时改了「标的类型」要能存回去），
  /// 只有 `market` 在「库里已有同一代码」时沿用库里那份 —— 交易所代码的
  /// 沪深北前缀直接影响去哪取数，不宜按首字母重新猜。
  Asset _draftAsset() {
    final code = _code.text.trim();
    final stored =
        _assetId == null ? null : context.read<AppState>().assetsById[_assetId];
    final reuseMarket = stored != null && stored.code == code;
    return Asset(
      id: _assetId,
      code: code,
      name: _name.text.trim(),
      kind: _kind,
      market: reuseMarket && stored.market.isNotEmpty
          ? stored.market
          : (_kind.isExchange ? MarketService.marketFor(code) : ''),
      // 从搜索结果带出的资产大类默认值（再平衡用），用户之后可在设置里改
      category: _category,
    );
  }

  static String _trim(double v) {
    if (v == 0) return '';
    var s = v.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDividend = _type == TxnType.dividend;
    // 本页所有输入框统一：标题**常驻在框线左上角的开口里**
    // —— 用户 2026-09-28：「线框左上角开口，申购费率（%）」。
    // Material 默认在框为空时会把标题掉进框内（就是被否掉的那种），
    // `FloatingLabelBehavior.always` 正好是"开口里常驻"这个行为。
    final theme = Theme.of(context);

    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      ),
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '记一笔' : '编辑记录'),
        actions: [
          if (widget.existing != null)
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            if (_locked) ...[
              _lockedHeader(context, state),
              const SizedBox(height: 16),
            ] else if (widget.existing != null) ...[
              // 编辑既有记录：**只看得到这笔本来的操作行为**，类型不给改
              // （用户 2026-09-29：「买入就是买入，卖出就是卖出，分红就是分红，
              //   再投就是再投，其他不相干的功能禁用」）
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: _lockedType, label: Text(_lockedType)),
                ],
                selected: {_lockedType},
                // 禁用：改类型等于把一笔买入改成卖出，那不是"编辑"是"记错重记"
                onSelectionChanged: null,
              ),
              const SizedBox(height: 20),
            ] else ...[
            SegmentedButton<TxnType>(
              segments: const [
                ButtonSegment(value: TxnType.buy, label: Text('买入')),
                ButtonSegment(value: TxnType.sell, label: Text('卖出')),
                ButtonSegment(value: TxnType.dividend, label: Text('分红')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _resetDerivedFlag();
                if (_type == TxnType.dividend) _navGen++; // 作废在途查询
                // 买入用申购费率、卖出用赎回费率 → 换类型要把费率框跟着换
                _reloadFeeRate();
                _syncDerived();
              }),
            ),
            const SizedBox(height: 20),

            // 账户
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _accountId,
                    decoration: const InputDecoration(labelText: '账户'),
                    items: [
                      for (final a in state.accounts)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _accountId = v;
                        // 场内费率是**券商（账户）属性**：换账户要把输入框换成那家的；
                        // 场外是按基金代码存的，换账户不影响（_reloadFeeRate 自己分流）
                        _reloadFeeRate();
                      });
                    },
                    validator: (v) => v == null ? '请选择账户' : null,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '新建账户',
                  onPressed: _addAccount,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 标的类型
            DropdownButtonFormField<AssetKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '标的类型'),
              items: [
                for (final k in AssetKind.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (v) {
                setState(() => _kind = v ?? AssetKind.fund);
                // 换类型会换主字段（场外基金买入填金额、场内买入填股数），
                // 先重置"谁是派生字段"再联动一次
                _resetDerivedFlag();
                // 场内↔场外 换的是一整套费率口径（佣金万几+免五 ↔ 申购/赎回%）
                _reloadFeeRate();
                _syncDerived();
                if (_code.text.trim().isNotEmpty) _syncNav();
              },
            ),
            const SizedBox(height: 16),

            // 搜索：代码 / 名称 / 拼音首拼，先在本地基础数据库里查
            TextFormField(
              controller: _code,
              decoration: InputDecoration(
                labelText: '代码 / 名称 / 首拼',
                hintText: '如 510300、沪深300、hs300',
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : (_code.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                                  _code.clear();
                                  _name.clear();
                                  _navHasTarget = false;
                                  _results = [];
                                  _showResults = false;
                                  _clsFilter = null;
                                  _subFilter = null;
                                }),
                          )),
              ),
              keyboardType: TextInputType.text,
              onChanged: _onCodeChanged,
              validator: (v) => (v == null || v.trim().isEmpty) ? '请输入代码' : null,
            ),
            if (_showResults) _buildSearchResults(context, state),
            const SizedBox(height: 16),

            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（可留空，自动获取）'),
            ),
            const SizedBox(height: 16),
            ],

            // 日期
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '日期',
                  suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                ),
                child: Text(fmtDateCn(_date)),
              ),
            ),
            if (!isDividend) ...[
              const SizedBox(height: 6),
              _navHintRow(),
            ],
            const SizedBox(height: 16),

            // 主字段随类型互换：场外基金买入先填金额、场内买入先填股数、卖出先填份额；
            // 派生字段独占一行
            if (!isDividend) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _primary == PrimaryField.amount
                        ? _amountField()
                        : _sharesField(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _priceField()),
                ],
              ),
              const SizedBox(height: 16),
              // 派生字段（场内买入/卖出的**金额**、场外买入的**份额**、卖出金额）
              // 与**费率框同一行** —— 用户要求：「统一放在金额/份额后面，同一行显示」，
              // 免五开关也做成了框里的圆点（见 _feeRateField）
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _primary == PrimaryField.amount
                        ? _sharesField()
                        : _amountField(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _feeRateField(state)),
                ],
              ),
              const SizedBox(height: 16),
            ],

            if (isDividend) ...[
              _amountField(dividend: true),
              const SizedBox(height: 16),
              // 分红没有手续费，这一格只是留着（渠道扣费之类）
              TextFormField(
                controller: _fee,
                decoration: const InputDecoration(labelText: '手续费（可选）'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            ] else ...[
              // 手续费：左「预测」（只读）· 中间向右双箭头（把预测搬进实际）· 右「实际」
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _predictedFeeBox(context, state)),
                  // 用户要求：箭头改成**向右双箭头**、放在预测与实际**之间**
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Tooltip(
                      message: '把预测值填入实际手续费',
                      child: IconButton(
                        onPressed: _applyPredictedFee,
                        icon: const Icon(Icons.keyboard_double_arrow_right,
                            size: 22),
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        constraints: const BoxConstraints(
                            minWidth: 36, minHeight: 36),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextFormField(
                      controller: _fee,
                      decoration: const InputDecoration(
                        labelText: '手续费（实际）',
                        helperText: '计入成本的那个数',
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      // 用户手改过实际手续费 → 不再用 FIFO 估算覆盖它
                      onChanged: (_) => _feeTouched = true,
                    ),
                  ),
                ],
              ),
            ],
            // 股票的**法定税费**（用户 2026-09-28：卖出要考虑印花税与过户费）：
            // 过户费双向、印花税只有卖出；ETF/LOF 两样都不收
            if (!isDividend && _kind == AssetKind.stock) ...[
              const SizedBox(height: 6),
              Text(
                _type == TxnType.sell
                    ? '卖股票＝佣金＋过户费万0.1＋印花税万5（法定费用，与佣金率无关）'
                    : '买股票＝佣金＋过户费万0.1（卖出时还要交印花税万5）',
                style:
                    TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
              ),
            ],
            const SizedBox(height: 16),

            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（可选）'),
              maxLines: 2,
            ),
            const SizedBox(height: 28),

            // 「保存」跟着"有没有改动"走：备注/金额这些框改了不会走 setState，
            // 所以这里直接听控制器，改一下按钮立刻亮/灭。
            ListenableBuilder(
              listenable: Listenable.merge(
                  [_code, _name, _shares, _price, _amount, _fee, _note]),
              builder: (_, _) => FilledButton(
                onPressed: _dirty ? _save : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // ---------------- 表单字段 ----------------

  /// 编辑既有记录时顶部显示的操作行为名。
  ///
  /// **「再投」要显示成再投**（用户 2026-09-29：「再投就是再投」）—— 红利再投在
  /// 库里就是一笔备注带 `红利再投 / 再投` 的买入（不掉现金），所以按备注现判，
  /// 与 `Txn.isReinvest` 同一套规则：改了备注这里也跟着变。
  String get _lockedType {
    if (_type != TxnType.buy) return _type.label;
    final n = _note.text.trim();
    return n.startsWith(Txn.reinvestNote) || n.startsWith('再投') ? '再投' : '买入';
  }

  /// 表单当前值的快照（只含**会被写进那笔记录**的字段）。
  ///
  /// 费率框不在里面：它不是这笔记录的一部分，改它是即时写进设置的。
  String _formSnapshot() {
    String num(TextEditingController c) =>
        (double.tryParse(c.text.trim()) ?? 0).toStringAsFixed(6);
    return [
      _type.name,
      '$_accountId',
      '$_assetId',
      _kind.name,
      _code.text.trim(),
      _name.text.trim(),
      num(_shares),
      num(_price),
      num(_amount),
      num(_fee),
      _note.text.trim(),
      fmtDate(_date),
      '$_pending',
    ].join('|');
  }

  /// 有没有改动过：新建的永远可存（空值由校验器拦），
  /// 编辑的要有改动才给存（用户 2026-09-29：「数据没有改动保存就不能用」）
  bool get _dirty =>
      widget.existing == null || _formSnapshot() != _initialSnapshot;

  /// 这一笔能不能按「待确认」记：**场外基金的买入与卖出**，且所选日期的净值不是精确命中
  /// （今天还没公布 → 查到的多半是上一交易日的）。
  ///
  /// 买入等的是**份额**、卖出等的是**金额**（场外赎回按份额下单，成交金额同样是按
  /// 当日净值确认的 —— 用户 2026-09-28 追问「场外基金当天卖出没有净值不也得待确认」）。
  ///
  /// **编辑既有记录时不出现**（用户 2026-09-29）：待确认是记账当时的选择，
  /// 事后改一笔老账不该把它翻回"待确认"。
  bool get _canPending =>
      widget.existing == null &&
      !_kind.isExchange &&
      (_type == TxnType.buy || _type == TxnType.sell) &&
      (_pending || _navFill == null || !_navFill!.exact);

  /// 日期下面那行净值提示：查到了显示净值所属日期，没查到就让用户手填；
  /// 场外基金当天净值没公布时，右侧还给一个「改为待确认」的开关
  /// （用户 2026-09-28 选的做法：先只记金额，份额等净值公布后自动补）。
  Widget _navHintRow() {
    // 还没填代码 / 还没为当前输入查过时是中性的「待查询」，不能显示成错误
    final hasCode = _navHasTarget;
    final queried = _navQueried;
    final failed = hasCode && queried && !_navBusy && _navFill == null;
    final color = failed ? const Color(0xFFD93A3A) : Theme.of(context).hintColor;
    final hint = _pending
        // 买入等份额、卖出等金额（赎回金额按当日净值确认）
        ? (_type == TxnType.sell
            ? '待确认：份额已记，赎回金额与到账等净值公布后自动补'
            : '待确认：先只记金额，等净值公布后自动补份额')
        : navFillHint(
            day: _date,
            fill: _navFill,
            busy: _navBusy,
            error: _navError,
            hasCode: hasCode,
            queried: queried,
            // 场外是「净值」、场内是「价格」
            noun: _traits.priceIsLive ? '价格' : '净值',
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 5),
          child: _navBusy
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _pending
                      ? Icons.schedule_outlined
                      : failed
                          ? Icons.error_outline
                          : (hasCode && queried)
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                  size: 14,
                  color: color,
                ),
        ),
        Expanded(
          child: Text(hint, style: TextStyle(fontSize: 11, color: color)),
        ),
        if (_canPending)
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => setState(() {
              _pending = !_pending;
              if (_pending) {
                // 净值留空 = 待确认；已确定的那一半保留：
                // 买入留金额（份额待补）、卖出留份额（金额待补）
                _price.clear();
                if (_type == TxnType.sell) {
                  _amount.clear();
                } else {
                  _shares.clear();
                }
              } else {
                // 切回「用查到的净值」：重新按日期查一次
                _syncNav();
              }
            }),
            child: Text(_pending ? '用查到的净值' : '改为待确认',
                style: const TextStyle(fontSize: 11)),
          ),
      ],
    );
  }

  /// 价格：按交易日期自动填入，也可手改；右侧按钮可重新查询
  Widget _priceField() {
    return TextFormField(
      controller: _price,
      decoration: InputDecoration(
        // 场外填的是净值、场内填的是成交价
        labelText: _traits.priceIsLive ? '价格' : '净值',
        helperText: '按日期自动填入',
        suffixIcon: _navBusy
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : IconButton(
                tooltip: '按日期重新查询',
                icon: const Icon(Icons.autorenew, size: 18),
                onPressed: _syncNav,
              ),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (v) {
        // 待确认：净值留空是有意的（等公布后自动补），不拦
        if (_pending) return null;
        final d = double.tryParse(v ?? '');
        if (d == null || d <= 0) return '请输入价格';
        return null;
      },
    );
  }

  /// 份额/股数：场外基金买入时是自动算出来的，场内买入与卖出一律是主输入
  Widget _sharesField() {
    final unit = _traits.unit;
    final isBuy = _type == TxnType.buy;
    final main = _primary == PrimaryField.shares; // 这一格是不是主输入
    final label = isBuy ? (main ? '买入$unit' : unit) : '卖出$unit';
    final helper = main
        // 场内买入：先填股数，金额跟着算
        ? (isBuy
            ? '按价格自动算出金额，也可手改'
            // 卖出：这里说的就是**可卖份额**（T+1 当日买入的不能卖）
            : '可卖 ${fmtSharesOf(widget.maxShares ?? 0, isFund: _traits.unitIsFund)} '
                '$unit（当日买入的 T+1 后才能卖）')
        // 场外买入：金额是主字段，这一格是算出来的
        : '按金额和净值自动算出，可手改';
    return TextFormField(
      controller: _shares,
      decoration: InputDecoration(labelText: label, helperText: helper),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (v) {
        // 待确认：**买入**时份额留空是有意的（等公布后自动补），不拦；
        // 卖出时份额是那一半已知的数，仍必须填
        if (_pending && _type == TxnType.buy) return null;
        final d = double.tryParse(v ?? '');
        if (d == null || d <= 0) return '请输入$unit';
        // 可卖份额（T+1：当日买的那部分当天不能卖）；0 也要拦，别让"可卖 0"被跳过
        final max = widget.maxShares;
        if (max != null && d > max + 1e-9) {
          final t = fmtSharesOf(max, isFund: _traits.unitIsFund);
          return '最多可卖 $t $unit';
        }
        return null;
      },
    );
  }

  /// 金额：场外基金买入时是主输入，场内买入与卖出时是自动算出来的，分红时是到账金额
  Widget _amountField({bool dividend = false}) {
    final isBuy = _type == TxnType.buy;
    final main = _primary == PrimaryField.amount;
    final derived = !dividend && !main;
    final helper = dividend
        ? '实际到账的现金'
        : (derived
            ? (isBuy ? '按${_traits.unit}和价格自动算出，可手改' : '按金额和净值自动算出，可手改')
            : '按净值自动算出${_traits.unit}');
    return TextFormField(
      controller: _amount,
      decoration: InputDecoration(
        labelText: dividend ? '分红到账金额' : (main ? '买入金额' : '金额'),
        helperText: helper,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (v) {
        // 待确认：**卖出**时金额留空是有意的（赎回金额按当日净值确认，等公布后自动补），
        // 不拦；买入时金额是那一半已知的数，仍必须填
        if (_pending && _type == TxnType.sell) return null;
        final d = double.tryParse(v ?? '');
        if (d == null || d <= 0) return '请输入金额';
        return null;
      },
    );
  }

  Future<void> _pickDate() async {
    final picked = await showCnDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _date = picked);
    // 日期是净值的取数依据：一改就按新日期重新查
    await _syncNav();
  }

  // ---------------- 锁定态的只读头部 ----------------

  Color get _typeColor => switch (_type) {
        TxnType.buy => const Color(0xFFD93A3A),
        TxnType.sell => const Color(0xFF1A9C5B),
        TxnType.dividend => const Color(0xFFB4770A),
      };

  Widget _lockedHeader(BuildContext context, AppState state) {
    final asset = _assetId == null ? null : state.assetsById[_assetId];
    final account = _accountId == null ? null : state.accountsById[_accountId];
    final title =
        asset == null ? _code.text : (asset.name.isEmpty ? asset.code : asset.name);
    final maxShares = widget.maxShares ?? 0;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _typeColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_type.label,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: _typeColor)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    '${asset?.code ?? ''} · ${asset?.kind.label ?? ''}'
                    '${account == null ? '' : ' · ${account.name}'}'
                    '${_type == TxnType.sell && widget.maxShares != null ? ' · 可卖 ${fmtSharesOf(maxShares, isFund: _traits.unitIsFund)}' : ''}',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 搜索基础数据库 ----------------

  void _onCodeChanged(String v) {
    _debounce?.cancel();
    final has = v.trim().isNotEmpty;
    if (has != _navHasTarget) {
      // 只在「有没有填代码」翻转时重画：净值提示行要跟着这句话换
      setState(() => _navHasTarget = has);
    }
    if (!has) {
      setState(() {
        _results = const [];
        _showResults = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), _runSearch);
  }

  Future<void> _runSearch() async {
    final kw = _code.text.trim();
    if (kw.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    final st = context.read<AppState>();
    final res = await st.searchAssets(
      kw,
      classFilter: _clsFilter,
      subFilter: _subFilter,
      allowRemote: _clsFilter == null && _subFilter == null,
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = res.rows;
      _fromRemote = res.fromRemote;
      _searchError = res.error;
      _showResults = true;
    });
  }

  void _setClassFilter(String? cls) {
    setState(() {
      _clsFilter = cls;
      _subFilter = null;
    });
    _runSearch();
  }

  void _setSubFilter(String? sub) {
    setState(() => _subFilter = sub);
    _runSearch();
  }

  /// 基础数据库里搜不到时的出口：**把用户填的代码当作新标的**
  ///
  /// 保存时 `saveTxnWithCash` 会按 (代码,类型) 走 `ensureAsset` —— 库里没有就
  /// 新建一条，所以这里只要把「已选中某个已有标的」的痕迹清掉、收起结果面板，
  /// 然后照常按日期查一次净值/价格（查不到也不影响保存）。
  void _addAsNewAsset() {
    setState(() {
      _assetId = null;
      _navHasTarget = true;
      _showResults = false;
      _results = const [];
      _clsFilter = null;
      _subFilter = null;
    });
    _syncNav();
    _syncDerived();
  }

  void _applyResult(SecurityRow r) {
    setState(() {
      _code.text = r.code;
      _name.text = r.name;
      _kind = r.assetKind;
      final cat = assetCategoryFor(r);
      if (cat.isNotEmpty) _category = cat;
      _navHasTarget = true;
      _showResults = false;
      _results = const [];
      _clsFilter = null;
      _subFilter = null;
      // 场外费率是**按基金代码**存的：选了新标的要把那一只的费率载进来
      _reloadFeeRate();
    });
    // 代码定了，净值就能按当前日期查出来了
    _syncNav();
    _syncDerived();
  }

  Widget _buildSearchResults(BuildContext context, AppState st) {
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);

    // chip 只列当前结果里实际出现的取值；已选中的筛选项始终保留，方便切回
    final classes = <String>{
      for (final r in _results)
        if (r.secClass.isNotEmpty) r.secClass,
    };
    if (_clsFilter != null) classes.add(_clsFilter!);
    final subs = <String>{
      for (final r in _results)
        if (r.secSub.isNotEmpty) r.secSub,
    };
    if (_subFilter != null) subs.add(_subFilter!);

    return Card(
      margin: const EdgeInsets.only(top: 8),
      elevation: 0,
      color: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_fromRemote ? '联网搜索' : '本地基础数据库', style: hint),
                const SizedBox(width: 8),
                if (_searching) Text('搜索中…', style: hint),
                const Spacer(),
                if (_searchError != null)
                  Flexible(
                    child: Text(
                      '联网失败',
                      style: hint.copyWith(color: const Color(0xFFD93A3A)),
                    ),
                  ),
              ],
            ),
            if (classes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('全部类型', style: TextStyle(fontSize: 12)),
                    selected: _clsFilter == null,
                    onSelected: (_) => _setClassFilter(null),
                  ),
                  for (final c in classes)
                    FilterChip(
                      label: Text(c, style: const TextStyle(fontSize: 12)),
                      selected: _clsFilter == c,
                      onSelected: (_) => _setClassFilter(c),
                    ),
                ],
              ),
            ],
            if (_clsFilter != null && subs.length > 1) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('全部', style: TextStyle(fontSize: 12)),
                    selected: _subFilter == null,
                    onSelected: (_) => _setSubFilter(null),
                  ),
                  for (final s in subs)
                    FilterChip(
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      selected: _subFilter == s,
                      onSelected: (_) => _setSubFilter(s),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            if (_results.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _searchError != null
                        ? '联网搜索失败，可先去「设置 → 数据维护中心」更新基础数据'
                        : '基础数据库里没有这个标的',
                    style: hint,
                  ),
                  // 搜不到也能记：按你填的代码/类型新建标的（保存时入库）
                  const SizedBox(height: 6),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 14),
                    label: Text(
                      '直接添加「${_code.text.trim()}」为新标的',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: _addAsNewAsset,
                  ),
                ],
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _results.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _results[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(r.subtitle, style: hint),
                      trailing: const Icon(Icons.add_circle_outline, size: 18),
                      onTap: () => _applyResult(r),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addAccount() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建账户'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '账户名称',
            hintText: '如 支付宝 / 天天基金 / 华泰证券',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final st = context.read<AppState>();
    await st.addAccount(name, '');
    if (!mounted) return;
    final created = st.accounts.where((a) => a.name == name).toList();
    if (created.isNotEmpty) {
      setState(() => _accountId = created.first.id);
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这笔记录？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().removeTxn(widget.existing!.id!);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_accountId == null) return;

    final st = context.read<AppState>();
    final asset = _draftAsset();

    final txn = Txn(
      id: widget.existing?.id,
      accountId: _accountId!,
      assetId: _assetId ?? 0,
      type: _type,
      date: _date,
      amount: double.tryParse(_amount.text) ?? 0,
      shares: _type == TxnType.dividend ? 0 : (double.tryParse(_shares.text) ?? 0),
      price: _type == TxnType.dividend ? 0 : (double.tryParse(_price.text) ?? 0),
      fee: double.tryParse(_fee.text) ?? 0,
      note: _note.text.trim(),
      // 待确认：份额/净值留空，等净值公布后由 fillPendingTxns 自动补
      pending: _pending,
    );

    // 买入/卖出/分红自动记入现金账户（联动常开，无需勾选）；
    // 手续费一律并进现金流（分红那格手续费也会扣，与写库口径一致）。
    // **待确认的卖出**：金额还不知道、赎回款也还没到账 → 当时不写现金流水，
    // 等净值公布后由 `fillPendingTxns()` 补上入账。
    final cashNote = _pending
        ? (_type == TxnType.sell
            ? '待确认：赎回金额与到账等净值公布后自动补'
            : '待确认：份额等净值公布后自动补')
        : switch (_type) {
            TxnType.buy => '买入扣款 ${fmtMoney(txn.amount + txn.fee)}',
            TxnType.sell => '卖出入账 ${fmtMoney(txn.amount - txn.fee)}',
            TxnType.dividend => '分红入账 ${fmtMoney(txn.amount - txn.fee)}',
          };
    await st.saveTxnWithCash(txn, asset);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_pending ? '已保存 · $cashNote' : '已保存 · $cashNote 已记入现金'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
