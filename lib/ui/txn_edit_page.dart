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
import '../logic/txn_form.dart';
import '../state/app_state.dart';
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

  /// 手续费是否还跟着成交金额自动算（用户手改过 / 编辑既有流水 → 不再自动覆盖）
  bool _autoFee = true;

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
    _fee.addListener(_onFeeChanged);
    // 编辑既有流水：手续费是既成事实，不许被费率自动算覆盖
    _autoFee = widget.existing == null;
    _feeRateCtrl.text = _wanText(st.feeRateOf(_accountId));

    // 进来就带着标的（从持仓详情页）时，先按当前日期查一次净值
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 预填的场景（从详情页卖出）不会有"变更事件"，这里补算一次手续费，
      // 否则会出现"助手写着 ¥5.00、框里却是空的"
      _syncFee();
      setState(() {});
      if (widget.existing == null && _code.text.isNotEmpty) _syncNav();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _shares.removeListener(_onSharesChanged);
    _price.removeListener(_onPriceChanged);
    _amount.removeListener(_onAmountChanged);
    _fee.removeListener(_onFeeChanged);
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

  /// 用户手改过手续费 → 之后不再按费率覆盖（与份额/金额同一套"谁是主字段"逻辑）
  void _onFeeChanged() {
    if (_writing) return;
    _autoFee = false;
    setState(() {}); // helper 文案要跟着变
  }

  void _onFeeRateChanged(String v) {
    // **即时生效**（不做防抖）：setFeeRate 会先把值写进内存再落库，
    // 所以紧接着的 _syncFee 就能用它算出金额；防抖的话当次填完费率是算不出来的
    final acc = _accountId;
    if (acc != null) {
      unawaited(context.read<AppState>().setFeeRate(acc, double.tryParse(v.trim())));
    }
    setState(() {});
    _syncFee();
  }

  /// 按「成交金额 × 费率」自动填手续费；**没设费率/金额为空就什么都不做**（不猜）
  void _syncFee() {
    if (_type == TxnType.dividend) return;
    if (!_autoFee) return;
    final acc = _accountId;
    if (acc == null) return;
    final st = context.read<AppState>();
    final amount = double.tryParse(_amount.text) ?? 0;
    final fee = st.feeForAmount(accountId: acc, kind: _kind, amount: amount);
    if (fee == null) return;
    _setText(_fee, fee.toStringAsFixed(2));
  }

  /// 手续费下面那行说明：把"这个数是怎么来的"摆出来，免得猜
  String? _feeHint() {
    if (_type == TxnType.dividend) return null;
    final st = context.read<AppState>();
    final wan = st.feeRateOf(_accountId);
    if (wan == null) return '留空即可；要自动算就在下面填佣金费率';
    final amount = double.tryParse(_amount.text) ?? 0;
    final fee = st.feeForAmount(accountId: _accountId, kind: _kind, amount: amount);
    if (fee == null) return '按万${_wanText(wan)} 算（先填金额 / 股数×价格）';
    final min = _kind.isExchange && !st.feeWaiveMinOf(_accountId)
        ? '（不足 5 元按 5 元）'
        : '';
    return '按万${_wanText(wan)} 算 = ¥${fee.toStringAsFixed(2)}$min'
        '${_autoFee ? '' : ' · 已按你手改的填'}';
  }

  void _onSharesChanged() {
    if (_writing) return;
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
    _syncFee();
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
    _syncFee();
  }

  void _onPriceChanged() {
    if (_writing) return;
    _syncDerived();
    _syncFee();
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
      // 价格是程序化写入的（`_setText` 期间监听器不动作），所以这里要显式补算一次
      // 手续费 —— 从详情页卖出时"助手写着 ¥5.00、框里却是空的"就是少了这一步
      _syncFee();
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

    return Scaffold(
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
                _syncDerived();
                _syncFee();
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
                      setState(() => _accountId = v);
                      // 费率是**券商（账户）属性**：换账户要把输入框换成那家的，
                      // 顺带按新费率重算一次手续费
                      _feeRateCtrl.text =
                          _wanText(context.read<AppState>().feeRateOf(v));
                      _syncFee();
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
                _syncDerived();
                _syncFee();
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
              if (_primary == PrimaryField.amount)
                _sharesField()
              else
                _amountField(),
              const SizedBox(height: 16),
            ],

            if (isDividend) ...[
              _amountField(dividend: true),
              const SizedBox(height: 16),
            ],

            TextFormField(
              controller: _fee,
              decoration: InputDecoration(
                labelText: '手续费（可选）',
                helperText: _feeHint(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            if (!isDividend) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _feeRateCtrl,
                      decoration: const InputDecoration(
                        labelText: '佣金费率（万分之几）',
                        helperText: '如 2.5 = 万2.5；留空则不自动算',
                        isDense: true,
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: _onFeeRateChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 免五：券商豁免"最低 5 元佣金"
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('免五',
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).hintColor)),
                      Switch(
                        value: state.feeWaiveMinOf(_accountId),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: _accountId == null
                            ? null
                            : (v) async {
                                await context
                                    .read<AppState>()
                                    .setFeeWaiveMin(_accountId!, v);
                                _syncFee();
                              },
                      ),
                    ],
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),

            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（可选）'),
              maxLines: 2,
            ),
            const SizedBox(height: 28),

            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 表单字段 ----------------

  /// 日期下面那行净值提示：查到了显示净值所属日期，没查到就让用户手填
  Widget _navHintRow() {
    // 还没填代码 / 还没为当前输入查过时是中性的「待查询」，不能显示成错误
    final hasCode = _navHasTarget;
    final queried = _navQueried;
    final failed = hasCode && queried && !_navBusy && _navFill == null;
    final color = failed ? const Color(0xFFD93A3A) : Theme.of(context).hintColor;
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
                  failed
                      ? Icons.error_outline
                      : (hasCode && queried)
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                  size: 14,
                  color: color,
                ),
        ),
        Expanded(
          child: Text(
            navFillHint(
              day: _date,
              fill: _navFill,
              busy: _navBusy,
              error: _navError,
              hasCode: hasCode,
              queried: queried,
              // 场外是「净值」、场内是「价格」
              noun: _traits.priceIsLive ? '价格' : '净值',
            ),
            style: TextStyle(fontSize: 11, color: color),
          ),
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
    );

    // 买入/卖出/分红自动记入现金账户（联动常开，无需勾选）
    final cashNote = switch (_type) {
      TxnType.buy => '买入扣款 ${fmtMoney(txn.amount + txn.fee)}',
      TxnType.sell => '卖出入账 ${fmtMoney(txn.amount - txn.fee)}',
      TxnType.dividend => '分红入账 ${fmtMoney(txn.amount)}',
    };
    await st.saveTxnWithCash(txn, asset);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存 · $cashNote 已记入现金'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
