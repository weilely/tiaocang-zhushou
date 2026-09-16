import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
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

    // 进来就带着标的（从持仓详情页）时，先按当前日期查一次净值
    if (widget.existing == null && _code.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNav());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _shares.removeListener(_onSharesChanged);
    _price.removeListener(_onPriceChanged);
    _amount.removeListener(_onAmountChanged);
    for (final c in [_code, _name, _shares, _price, _amount, _fee, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------- 金额 / 份额 / 净值的联动 ----------------

  /// 主字段随交易类型互换：买入先填金额，卖出先填份额
  void _resetDerivedFlag() {
    switch (primaryFieldFor(_type)) {
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

  /// 金额变了算份额（买入）；份额变了算金额（卖出）
  void _syncDerived() {
    if (_type == TxnType.dividend) return;
    final price = double.tryParse(_price.text) ?? 0;
    if (price <= 0) return;

    if (_type == TxnType.buy) {
      if (!_autoShares) return;
      final amount = double.tryParse(_amount.text) ?? 0;
      final s = derivedShares(amount: amount, price: price, kind: _kind);
      if (s != null) _setText(_shares, _trim(s));
    } else {
      if (!_autoAmount) return;
      final shares = double.tryParse(_shares.text) ?? 0;
      final a = derivedAmount(shares: shares, price: price);
      // 金额是钱，落到分
      if (a != null) _setText(_amount, _trim(double.parse(a.toStringAsFixed(2))));
    }
  }

  void _onSharesChanged() {
    if (_writing) return;
    if (_type == TxnType.buy) {
      _autoShares = false; // 份额被手改，不再自动推
    } else {
      _autoAmount = true; // 卖出：份额是主字段，手改后金额跟着算
    }
    _syncDerived();
  }

  void _onAmountChanged() {
    if (_writing) return;
    if (_type == TxnType.buy) {
      _autoShares = true;
    } else {
      _autoAmount = false;
    }
    _syncDerived();
  }

  void _onPriceChanged() {
    if (_writing) return;
    _syncDerived();
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
                    onChanged: (v) => setState(() => _accountId = v),
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

            // 主字段随类型互换：买入先金额、卖出先份额；派生字段独占一行
            if (!isDividend) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _type == TxnType.buy
                        ? _amountField()
                        : _sharesField(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _priceField()),
                ],
              ),
              const SizedBox(height: 16),
              if (_type == TxnType.buy) _sharesField() else _amountField(),
              const SizedBox(height: 16),
            ],

            if (isDividend) ...[
              _amountField(dividend: true),
              const SizedBox(height: 16),
            ],

            TextFormField(
              controller: _fee,
              decoration: const InputDecoration(labelText: '手续费（可选）'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
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
            ),
            style: TextStyle(fontSize: 11, color: color),
          ),
        ),
      ],
    );
  }

  /// 净值：按交易日期自动填入，也可手改；右侧按钮可重新查询
  Widget _priceField() {
    return TextFormField(
      controller: _price,
      decoration: InputDecoration(
        labelText: '净值 / 价格',
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
                tooltip: '按日期重新查询净值',
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

  /// 份额：买入时是自动算出来的，卖出时是主输入
  Widget _sharesField() {
    final derived = _type == TxnType.buy;
    return TextFormField(
      controller: _shares,
      decoration: InputDecoration(
        labelText: derived ? '份额' : '卖出份额',
        helperText: derived ? '按金额和净值自动算出，可手改' : '按净值自动算出金额',
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (v) {
        final d = double.tryParse(v ?? '');
        if (d == null || d <= 0) return '请输入份额';
        final max = widget.maxShares;
        if (max != null && max > 0 && d > max + 1e-9) {
          return '最多可卖 ${fmtShares(max)} 份';
        }
        return null;
      },
    );
  }

  /// 金额：买入时是主输入，卖出时是自动算出来的，分红时是到账金额
  Widget _amountField({bool dividend = false}) {
    final derived = !dividend && _type == TxnType.sell;
    return TextFormField(
      controller: _amount,
      decoration: InputDecoration(
        labelText: dividend ? '分红到账金额' : (derived ? '金额' : '买入金额'),
        helperText: dividend
            ? '实际到账的现金'
            : (derived ? '按份额和净值自动算出，可手改' : '按净值自动算出份额'),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _typeColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
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
                    '${_type == TxnType.sell && maxShares > 0 ? ' · 可卖 ${fmtShares(maxShares)}' : ''}',
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
              Text(
                _searchError != null
                    ? '联网搜索失败，可先去「设置 → 数据维护中心」更新基础数据'
                    : '没有匹配的标的',
                style: hint,
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
