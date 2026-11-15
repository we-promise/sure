import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/budget_category_transactions_screen.dart';
import 'package:sure_mobile/services/transactions_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

String _page(String name, {required int page, required int pages}) =>
    '{"transactions":[{"id":"$name","account":{"id":"a1"},"name":"$name",'
    '"date":"2026-10-03","amount":"\$1.00","currency":"USD",'
    '"classification":"expense",'
    '"category":{"id":"cat_food","name":"Food"}}],'
    '"pagination":{"page":$page,"per_page":50,"total_count":2,'
    '"total_pages":$pages}}';

void main() {
  Widget harness(
    TransactionsService service, {
    Future<String?> Function()? loader,
  }) {
    return ChangeNotifierProvider<PrivacyProvider>(
      create: (_) => PrivacyProvider(initialHidden: false),
      child: MaterialApp(
        theme: SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BudgetCategoryTransactionsScreen(
          title: 'Food',
          periodLabel: 'October 2026',
          categoryIds: const ['cat_food'],
          startDate: DateTime(2026, 10, 1),
          endDate: DateTime(2026, 10, 31),
          service: service,
          accessTokenLoader: loader ?? () async => 'token',
        ),
      ),
    );
  }

  testWidgets('without an access token shows the error state, not empty',
      (tester) async {
    final service = TransactionsService(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    await tester.pumpWidget(harness(service, loader: () async => null));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load transactions"), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.textContaining('No transactions'), findsNothing);
  });

  testWidgets('retrying a failed refresh reloads page one', (tester) async {
    final pages = <String>[];
    var failNext = false;
    final service = TransactionsService(
      client: MockClient((request) async {
        final page = request.url.queryParameters['page']!;
        pages.add(page);
        if (failNext) {
          failNext = false;
          return http.Response('{}', 500);
        }
        return http.Response(_page('Row $page', page: 1, pages: 2), 200);
      }),
    );
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    expect(pages, ['1']);

    failNext = true;
    await tester.fling(find.text('Row 1'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(pages, ['1', '1']);
    expect(find.text('Try Again'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(pages, ['1', '1', '1']);
    expect(find.text('Row 1'), findsOneWidget);
  });
}
