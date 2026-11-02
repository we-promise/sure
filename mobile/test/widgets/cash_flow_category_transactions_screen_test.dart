import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/cash_flow.dart';
import 'package:sure_mobile/models/category.dart';
import 'package:sure_mobile/models/transaction.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/cash_flow_category_transactions_screen.dart';
import 'package:sure_mobile/screens/cash_flow_screen.dart'
    show AccessTokenLoader;
import 'package:sure_mobile/services/transactions_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

import '../support/fake_categories_service.dart';

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

String _row(
  String name, {
  String amount = r'$1.00',
  String classification = 'expense',
  Map<String, Object> extra = const {},
}) {
  final fields = {
    'id': name,
    'account': {'id': 'a1'},
    'name': name,
    'date': '2026-10-03',
    'amount': amount,
    'currency': 'USD',
    'classification': classification,
    'category': {'id': 'cat_groceries', 'name': 'Groceries'},
    ...extra,
  };
  return jsonEncode(fields);
}

String _rows(List<String> rows, {required int page, required int pages}) =>
    '{"transactions":[${rows.join(',')}],"pagination":{"page":$page,'
    '"per_page":50,"total_count":${rows.length},"total_pages":$pages}}';

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
    FakeCategoriesService? categories,
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
          categoriesService: categories ?? FakeCategoriesService(),
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

  group('subcategories', () {
    List<List<String>> requested = [];
    TransactionsService recording() => TransactionsService(
          client: MockClient((request) async {
            requested.add(request.url.queryParametersAll['category_ids[]']!);
            return http.Response(_page(['Row'], page: 1, pages: 1), 200);
          }),
        );
    setUp(() => requested = []);

    testWidgets('includes subcategories the report leaves out', (tester) async {
      final categories = FakeCategoriesService(subcategories: [
        Category(id: 'cat_snacks', name: 'Snacks'),
      ]);
      await tester.pumpWidget(harness(recording(), categories: categories));
      await tester.pumpAndSettle();

      expect(categories.parentIds, ['cat_groceries']);
      expect(requested, [
        ['cat_groceries', 'cat_snacks'],
      ]);
      expect(find.text('Row'), findsOneWidget);
    });

    testWidgets('falls back to the report categories when the lookup fails',
        (tester) async {
      final categories = FakeCategoriesService(
        response: {'success': false, 'error': 'Failed to fetch categories'},
      );
      await tester.pumpWidget(harness(recording(), categories: categories));
      await tester.pumpAndSettle();

      expect(requested, [
        ['cat_groceries'],
      ]);
      expect(find.text('Row'), findsOneWidget);
    });

    testWidgets('a 401 from the lookup logs the session out', (tester) async {
      var logouts = 0;
      final categories = FakeCategoriesService(
        response: {'success': false, 'error': 'unauthorized'},
      );
      await tester.pumpWidget(harness(
        recording(),
        categories: categories,
        onUnauthorized: (_) async => logouts++,
      ));
      await tester.pumpAndSettle();

      expect(logouts, 1);
      expect(requested, isEmpty);
    });
  });

  group('rows the report does not count (#4422 fields)', () {
    testWidgets('hides split parents, excluded rows and transfer kinds',
        (tester) async {
      final service = TransactionsService(
        client: MockClient((_) async => http.Response(
              _rows([
                _row('Plain'),
                _row('Split parent', extra: {'split_parent': true}),
                _row('Split child', extra: {'split_parent': false}),
                _row('Excluded', extra: {'excluded': true}),
                _row('Transfer', extra: {'kind': 'funds_movement'}),
                _row('Card payment', extra: {'kind': 'cc_payment'}),
                _row('One time', extra: {'kind': 'one_time'}),
              ], page: 1, pages: 1),
              200,
            )),
      );

      await tester.pumpWidget(harness(service));
      await tester.pumpAndSettle();

      expect(find.text('Plain'), findsOneWidget);
      expect(find.text('Split child'), findsOneWidget);
      for (final hidden in [
        'Split parent',
        'Excluded',
        'Transfer',
        'Card payment',
        'One time',
      ]) {
        expect(find.text(hidden), findsNothing, reason: hidden);
      }
    });

    testWidgets('shows a negative loan payment as an outflow', (tester) async {
      final service = TransactionsService(
        client: MockClient((_) async => http.Response(
              _rows([
                _row(
                  'Loan',
                  amount: r'-$250.00',
                  classification: 'income',
                  extra: {'kind': 'loan_payment'},
                ),
                _row(
                  'Refund',
                  amount: r'-$5.00',
                  classification: 'income',
                  extra: {'kind': 'standard'},
                ),
              ], page: 1, pages: 1),
              200,
            )),
      );

      await tester.pumpWidget(harness(service));
      await tester.pumpAndSettle();

      expect(find.text(r'-$250.00'), findsOneWidget);
      // A refund keeps its direction.
      expect(find.text(r'+$5.00'), findsOneWidget);
    });

    testWidgets('fetches the next page when a whole page is filtered out',
        (tester) async {
      final pages = <String>[];
      final service = TransactionsService(
        client: MockClient((request) async {
          final page = request.url.queryParameters['page']!;
          pages.add(page);
          return http.Response(
            page == '1'
                ? _rows([
                    _row('Parent', extra: {'split_parent': true}),
                  ], page: 1, pages: 2)
                : _rows([_row('Child')], page: 2, pages: 2),
            200,
          );
        }),
      );

      await tester.pumpWidget(harness(service));
      await tester.pumpAndSettle();

      expect(pages, ['1', '2']);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Parent'), findsNothing);
    });

    test('older servers without the fields show every row', () {
      final t = Transaction.fromJson(jsonDecode(_row(
        'Old',
        amount: r'-$5.00',
        classification: 'income',
      )) as Map<String, dynamic>);
      expect(countsInCashFlow(t), isTrue);
      expect(isCashFlowIncome(t), isTrue);
    });

    test('an investment contribution counts as an outflow', () {
      final t = Transaction.fromJson(jsonDecode(_row(
        'Contribution',
        amount: r'-$100.00',
        classification: 'income',
        extra: {'kind': 'investment_contribution'},
      )) as Map<String, dynamic>);
      expect(countsInCashFlow(t), isTrue);
      expect(isCashFlowIncome(t), isFalse);
    });
  });
}
