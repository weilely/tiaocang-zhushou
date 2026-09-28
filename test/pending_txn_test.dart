import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/models.dart';
import 'package:invest_tracker/state/app_state.dart';
import 'package:invest_tracker/ui/txn_edit_page.dart';
import 'package:provider/provider.dart';

/// 「待确认」（用户 2026-09-28 选的做法）：场外基金当天净值没公布时，
/// **买入**先只记金额、**卖出**先只记份额，等净值公布后自动补另一半。
///
/// 卖出那条是用户追问的：「场外基金当天卖出没有净值不也得待确认」
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required AssetKind kind,
    required TxnType type,
    double? maxShares,
  }) async {
    tester.view.physicalSize = const Size(400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final st = AppState()..loading = false;
    st.accounts = [Account(id: 1, name: '测试账户')];
    st.accountFilter = 1;
    st.feeRates[1] = 0.85;

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: st,
      child: MaterialApp(
        home: TxnEditPage(
          presetAccountId: 1,
          presetType: type,
          presetAsset: Asset(
            code: kind == AssetKind.fund ? '025497' : '510300',
            name: '测试标的',
            kind: kind,
          ),
          maxShares: maxShares,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('场外基金**卖出**也给「改为待确认」（赎回金额要等净值）', (tester) async {
    await pump(tester,
        kind: AssetKind.fund, type: TxnType.sell, maxShares: 800);
    expect(find.text('改为待确认'), findsOneWidget,
        reason: '卖出同样按当日净值确认金额，没净值就得待确认');
  });

  testWidgets('场外基金**买入**也有「改为待确认」', (tester) async {
    await pump(tester, kind: AssetKind.fund, type: TxnType.buy);
    expect(find.text('改为待确认'), findsOneWidget);
  });

  testWidgets('场内（ETF）不给待确认：本来就有实时价', (tester) async {
    await pump(tester,
        kind: AssetKind.etf, type: TxnType.sell, maxShares: 1000);
    expect(find.text('改为待确认'), findsNothing);
  });
}
