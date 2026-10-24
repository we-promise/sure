import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/cash_flow.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/cash_flow_category_transactions_screen.dart';
import 'package:sure_mobile/screens/cash_flow_screen.dart'
    show AccessTokenLoader;
import 'package:sure_mobile/services/transactions_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

String _page(List<String> names, {required int page, required int pages}) {
  final rows = [
    for (final name in names)
      '{"id":"$name","account":{"id":"a1"},"name":"$name",'
          '"date":"2026-10-03","amount":"\$1.00","currency":"USD",'
          '"classification":"expense",'
          '"category":{"id":"cat_groceries","name":"Groceries"}}',
  ].join(',');
  return '{"transactions":[$rows],"pagination":{"page":$page,'
      '"per_page":50,"total_count":${names.length},"total_pages":$pages}}';
}

void main() {
  const category = CashFlowCategory(
    id: 'expense_groceries',
    name: 'Groceries',
    side: CashFlowSide.expense,
    amount: 10,
    percentage: 100,
    categoryId: 'cat_groceries',
  );
  final range =
      CashFlowDateRange(DateTime(2026, 10, 1), DateTime(2026, 10, 19));

  Widget harness(
    TransactionsService service, {
    AccessTokenLoader? loader,
    Future<void> Function(BuildContext context)? onUnauthorized,
  }) {
    return ChangeNotifierProvider<PrivacyProvider>.value(
      value: PrivacyProvider(initialHidden: false),
      child: MaterialApp(
        theme: SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CashFlowCategoryTransactionsScreen(
          category: category,
          range: range,
          service: service,
          accessTokenLoader: loader ?? (_) async => 'token',
          onUnauthorized: onUnauthorized,
        ),
      ),
    );
  }

  testWidgets('drops a page that was in flight when the list was refreshed',
      (tester) async {
    final pending = <Completer<http.Response>>[];
    final pages = <String>[];
    final service = TransactionsService(
      client: MockClient((request) {
        pages.add(request.url.queryParameters['page']!);
        final completer = Completer<http.Response>();
        pending.add(completer);
        return completer.future;
      }),
    );

    await tester.pumpWidget(harness(service));
    await tester.pump();
    expect(pages, ['1']);
    pending
        .removeAt(0)
        .complete(http.Response(_page(['Old A'], page: 1, pages: 2), 200));
    await tester.pumpAndSettle();
    expect(find.text('Old A'), findsOneWidget);

    // Page 2 starts loading, then the user pulls to refresh before it lands.
    final state = tester.state(find.byType(CashFlowCategoryTransactionsScreen))
        as dynamic;
    unawaited(state.loadMoreForTest() as Future<void>);
    await tester.pump();
    expect(pages, ['1', '2']);
    final refresh = state.refreshForTest() as Future<void>;
    await tester.pump();
    expect(pages, ['1', '2', '1']);

    // The stale page 2 arrives after the refresh started: it is ignored.
    pending
        .removeAt(0)
        .complete(http.Response(_page(['Stale B'], page: 2, pages: 2), 200));
    await tester.pump();
    pending
        .removeAt(0)
        .complete(http.Response(_page(['Fresh A'], page: 1, pages: 1), 200));
    await refresh;
    await tester.pumpAndSettle();

    expect(find.text('Fresh A'), findsOneWidget);
    expect(find.text('Stale B'), findsNothing);
    expect(find.text('Old A'), findsNothing);
  });

  testWidgets('shows the error state when the access token loader throws',
      (tester) async {
    final service = TransactionsService(
      client: MockClient(
          (_) async => http.Response(_page(['Never'], page: 1, pages: 1), 200)),
    );
    await tester.pumpWidget(harness(
      service,
      loader: (_) async => throw Exception('storage failed'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Never'), findsNothing);
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a 401 logs the session out', (tester) async {
    var logouts = 0;
    final service = TransactionsService(
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    await tester.pumpWidget(harness(
      service,
      onUnauthorized: (_) async => logouts++,
    ));
    await tester.pumpAndSettle();

    expect(logouts, 1);
  });
}
