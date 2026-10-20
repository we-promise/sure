import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/category.dart' as models;
import 'package:sure_mobile/models/offline_transaction.dart';
import 'package:sure_mobile/models/transaction_split.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/providers/categories_provider.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/providers/transaction_splits_provider.dart';
import 'package:sure_mobile/providers/transactions_provider.dart';
import 'package:sure_mobile/screens/transaction_split_screen.dart';
import 'package:sure_mobile/services/connectivity_service.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/services/transaction_splits_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/utils/split_math.dart';
import 'package:sure_mobile/widgets/sure_button.dart';
import 'package:sure_mobile/widgets/transaction_split_section.dart';

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  _FakeAuthProvider({this.token = 'token'});

  final String? token;

  @override
  Future<String?> getValidAccessToken() async => token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectivity extends ChangeNotifier implements ConnectivityService {
  _FakeConnectivity({required this.online});

  bool online;

  void setOnline(bool value) {
    online = value;
    notifyListeners();
  }

  @override
  bool get isOnline => online;

  @override
  bool get isOffline => !online;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCategoriesProvider extends CategoriesProvider {
  @override
  List<models.Category> get categories => [
        models.Category(id: 'cat_food', name: 'Food'),
        models.Category(id: 'cat_home', name: 'Home'),
      ];

  @override
  Future<void> fetchCategories({required String accessToken}) async {}
}

class _RecordingTransactionsProvider extends TransactionsProvider {
  final List<List<String>> refreshes = [];

  @override
  Future<void> refreshAfterSplitChange({
    required String accessToken,
    required String accountId,
    List<String> removedChildIds = const [],
  }) async {
    refreshes.add(removedChildIds);
  }
}

String _splitJson({
  String parentId = 'parent_1',
  String amountDecimal = '100.0',
}) {
  return jsonEncode({
    'transaction_id': parentId,
    'amount': r'$100.00',
    'amount_decimal': amountDecimal,
    'amount_cents': 10000,
    'currency': 'USD',
    'children': [
      {
        'id': 'child_1',
        'name': 'Groceries',
        'amount': r'$60.00',
        'currency': 'USD',
        'date': '2026-06-01',
        'classification': 'expense',
        'account': {'id': 'acct_1'},
        'category': {'id': 'cat_food', 'name': 'Food'},
        'amount_decimal': '60.0',
        'excluded': false,
      },
      {
        'id': 'child_2',
        'name': 'Household',
        'amount': r'$40.00',
        'currency': 'USD',
        'date': '2026-06-01',
        'classification': 'expense',
        'account': {'id': 'acct_1'},
        'category': null,
        'amount_decimal': '40.0',
        'excluded': true,
      },
    ],
  });
}

class _Harness {
  _Harness({
    bool online = true,
    bool hidden = false,
    MockClientHandler? handler,
    String? token = 'token',
  })  : auth = _FakeAuthProvider(token: token),
        privacy = PrivacyProvider(initialHidden: hidden),
        connectivity = _FakeConnectivity(online: online),
        transactions = _RecordingTransactionsProvider() {
    splits = TransactionSplitsProvider(
      service: TransactionSplitsService(
        client: MockClient((request) async {
          requests.add(request);
          if (handler != null) return handler(request);
          return http.Response(_splitJson(), 200);
        }),
      ),
    )..setConnectivityService(connectivity);
  }

  final _FakeAuthProvider auth;
  final _FakeConnectivity connectivity;
  final PrivacyProvider privacy;
  final _RecordingTransactionsProvider transactions;
  late final TransactionSplitsProvider splits;
  final List<http.Request> requests = [];

  Widget wrap(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<CategoriesProvider>.value(
          value: _FakeCategoriesProvider(),
        ),
        ChangeNotifierProvider<PrivacyProvider>.value(value: privacy),
        ChangeNotifierProvider<TransactionsProvider>.value(
          value: transactions,
        ),
        ChangeNotifierProvider<TransactionSplitsProvider>.value(value: splits),
      ],
      child: MaterialApp(
        theme: SureTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
  }
}

/// Pushes [child] on top of a blank home so the editor can pop on save.
class _Launcher extends StatefulWidget {
  const _Launcher(this.child);

  final Widget child;

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).push(
        MaterialPageRoute<bool>(builder: (_) => widget.child),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

SplitEditorTarget _target({String amount = '100', String currency = 'USD'}) {
  return SplitEditorTarget(
    transactionId: 'parent_1',
    accountId: 'acct_1',
    name: 'Costco',
    date: '2026-06-01',
    currency: currency,
    categoryId: 'cat_food',
    amountUnits: SplitMath.parseUnits(amount)!,
  );
}

Finder _field(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(TextFormField),
    );

String _remaining(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('split-remaining-amount'))).data!;

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<SureButton>(find.byKey(const Key('split-save'))).onPressed !=
    null;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
  });

  Future<void> useTallView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('TransactionSplitScreen', () {
    testWidgets('tracks the remaining amount and only saves when balanced',
        (tester) async {
      await useTallView(tester);
      final harness = _Harness(
        handler: (_) async => http.Response(_splitJson(), 201),
      );
      await tester.pumpWidget(
        harness.wrap(_Launcher(TransactionSplitScreen(target: _target()))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Costco'), findsWidgets);
      expect(_remaining(tester), r'$100.00');
      expect(_saveEnabled(tester), isFalse);

      await tester.enterText(_field('split-amount-0'), '60');
      await tester.pump();
      expect(_remaining(tester), r'$40.00');
      expect(_saveEnabled(tester), isFalse);

      await tester.enterText(_field('split-name-1'), 'Household');
      await tester.enterText(_field('split-amount-1'), '40.5');
      await tester.pump();
      expect(_remaining(tester), r'-$0.50');
      expect(
        find.text('Split amounts must equal the original transaction amount.'),
        findsOneWidget,
      );

      await tester.enterText(_field('split-amount-1'), '40');
      await tester.pump();
      expect(_remaining(tester), r'$0.00');
      expect(_saveEnabled(tester), isTrue);

      await tester.tap(find.byKey(const Key('split-save')));
      await tester.pumpAndSettle();

      expect(harness.requests, hasLength(1));
      final request = harness.requests.single;
      expect(request.method, 'POST');
      final splits =
          ((jsonDecode(request.body) as Map)['split'] as Map)['splits'] as List;
      expect(splits[0], {
        'name': 'Costco',
        'amount': '60.0000',
        'category_id': 'cat_food',
      });
      expect(splits[1], {
        'name': 'Household',
        'amount': '40.0000',
        'category_id': null,
      });
      expect(harness.transactions.refreshes, hasLength(1));
      expect(harness.splits.isSplitParent('parent_1'), isTrue);
    });

    testWidgets('sends income amounts with the parent sign', (tester) async {
      await useTallView(tester);
      final harness = _Harness(
        handler: (_) async =>
            http.Response(_splitJson(amountDecimal: '-100.0'), 201),
      );
      await tester.pumpWidget(
        harness.wrap(
          _Launcher(TransactionSplitScreen(target: _target(amount: '-100'))),
        ),
      );
      await tester.pumpAndSettle();

      expect(_remaining(tester), r'$100.00');
      await tester.enterText(_field('split-amount-0'), '70');
      await tester.enterText(_field('split-name-1'), 'Bonus');
      await tester.enterText(_field('split-amount-1'), '30');
      await tester.pump();
      await tester.tap(find.byKey(const Key('split-save')));
      await tester.pumpAndSettle();

      final splits = ((jsonDecode(harness.requests.single.body) as Map)['split']
          as Map)['splits'] as List;
      expect(splits.map((s) => s['amount']), ['-70.0000', '-30.0000']);
    });

    testWidgets('rejects amounts finer than the currency allows',
        (tester) async {
      await useTallView(tester);
      final harness = _Harness();
      await tester.pumpWidget(
        harness.wrap(
          _Launcher(
            TransactionSplitScreen(
              target: _target(amount: '1500', currency: 'JPY'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_field('split-amount-0'), '1000.5');
      await tester.pump();
      expect(find.text('Use at most 0 decimal places'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('editing prefills rows and replaces the split with PATCH',
        (tester) async {
      await useTallView(tester);
      final harness = _Harness();
      final existing = TransactionSplit.fromJson(
        jsonDecode(_splitJson()) as Map<String, dynamic>,
      );
      harness.splits.remember(existing);

      await tester.pumpWidget(
        harness.wrap(
          _Launcher(
            TransactionSplitScreen(target: _target(), existing: existing),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit split'), findsOneWidget);
      expect(find.text('60.00'), findsOneWidget);
      expect(find.text('40.00'), findsOneWidget);
      expect(_remaining(tester), r'$0.00');

      // Removing a row unbalances the split until the amount is reassigned.
      await tester.tap(find.byKey(const Key('split-remove-row-1')));
      await tester.pump();
      expect(_remaining(tester), r'$40.00');
      expect(_saveEnabled(tester), isFalse);

      await tester.tap(find.byKey(const Key('split-add-row')));
      await tester.pump();
      await tester.enterText(_field('split-name-1'), 'Household');
      await tester.enterText(_field('split-amount-1'), '40');
      await tester.pump();
      await tester.tap(find.byKey(const Key('split-save')));
      await tester.pumpAndSettle();

      expect(harness.requests.single.method, 'PATCH');
      // Response reuses the same child ids, so nothing is reported removed.
      expect(harness.transactions.refreshes.single, isEmpty);
    });

    testWidgets('masks amounts in privacy mode', (tester) async {
      await useTallView(tester);
      final harness = _Harness(hidden: true);
      await tester.pumpWidget(
        harness.wrap(_Launcher(TransactionSplitScreen(target: _target()))),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('split-original-amount')))
            .data,
        r'$••••',
      );
      expect(_remaining(tester), r'$••••');
      final amountField = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('split-amount-0')),
          matching: find.byType(EditableText),
        ),
      );
      expect(amountField.obscureText, isTrue);
    });

    testWidgets('cannot save while offline', (tester) async {
      await useTallView(tester);
      final harness = _Harness(online: false);
      await tester.pumpWidget(
        harness.wrap(_Launcher(TransactionSplitScreen(target: _target()))),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_field('split-amount-0'), '60');
      await tester.enterText(_field('split-name-1'), 'Household');
      await tester.enterText(_field('split-amount-1'), '40');
      await tester.pump();

      expect(
        find.text("You're offline. Splits can only be saved while connected."),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isFalse);
      expect(harness.requests, isEmpty);
    });
  });

  group('TransactionSplitSection', () {
    OfflineTransaction transaction(String id) => OfflineTransaction(
          id: id,
          localId: 'local_$id',
          accountId: 'acct_1',
          name: 'Costco',
          date: '2026-06-01',
          amount: r'$100.00',
          currency: 'USD',
          nature: 'expense',
          syncStatus: SyncStatus.synced,
        );

    Widget screen(OfflineTransaction t) => Scaffold(
          body: SingleChildScrollView(
            child: TransactionSplitSection(transaction: t),
          ),
        );

    testWidgets('lists the children of a split parent', (tester) async {
      await useTallView(tester);
      final harness = _Harness();
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      expect(find.text('Split entries'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('(uncategorized)'), findsOneWidget);
      expect(find.text(r'$60.00'), findsOneWidget);
      expect(find.text(r'$40.00'), findsOneWidget);
      expect(find.text('Edit split'), findsOneWidget);
      expect(find.text('Unsplit'), findsOneWidget);
    });

    testWidgets('marks a child as part of a split', (tester) async {
      await useTallView(tester);
      final harness = _Harness();
      await tester.pumpWidget(harness.wrap(screen(transaction('child_1'))));
      await tester.pumpAndSettle();

      expect(find.text('Part of split'), findsOneWidget);
      expect(harness.splits.isSplitChild('child_1'), isTrue);
      expect(harness.splits.parentIdFor('child_1'), 'parent_1');
    });

    testWidgets('offers to split an unsplit transaction', (tester) async {
      await useTallView(tester);
      final harness = _Harness(
        handler: (_) async => http.Response(
          '{"error":"not_found","message":"Transaction is not split"}',
          404,
        ),
      );
      await tester.pumpWidget(harness.wrap(screen(transaction('tx_1'))));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('split-start')), findsOneWidget);

      await tester.tap(find.byKey(const Key('split-start')));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSplitScreen), findsOneWidget);
      expect(_remaining(tester), r'$100.00');
    });

    testWidgets('unsplit asks first, then calls DELETE', (tester) async {
      await useTallView(tester);
      final harness = _Harness(
        handler: (request) async => request.method == 'DELETE'
            ? http.Response('', 204)
            : http.Response(_splitJson(), 200),
      );
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('split-unsplit')));
      await tester.pumpAndSettle();
      expect(find.text('Unsplit transaction'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Unsplit'));
      await tester.pumpAndSettle();

      expect(harness.requests.last.method, 'DELETE');
      expect(harness.splits.isSplitParent('parent_1'), isFalse);
      expect(
        harness.transactions.refreshes.single,
        ['child_1', 'child_2'],
      );
    });

    testWidgets('masks child amounts in privacy mode', (tester) async {
      await useTallView(tester);
      final harness = _Harness(hidden: true);
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      expect(find.text(r'$60.00'), findsNothing);
      expect(find.text(r'$••••'), findsNWidgets(2));
    });

    testWidgets('is read-only offline', (tester) async {
      await useTallView(tester);
      final harness = _Harness(online: false);
      harness.splits.remember(
        TransactionSplit.fromJson(
          jsonDecode(_splitJson()) as Map<String, dynamic>,
        ),
      );
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      expect(
        find.text('Connect to the internet to view or edit splits.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SureButton>(find.byKey(const Key('split-edit')))
            .onPressed,
        isNull,
      );
      expect(harness.requests, isEmpty);
    });

    testWidgets('offers a retry when the split lookup fails', (tester) async {
      await useTallView(tester);
      var fail = true;
      final harness = _Harness(
        handler: (_) async => fail
            ? http.Response('{"error":"boom"}', 500)
            : http.Response(_splitJson(), 200),
      );
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load split details."), findsOneWidget);
      expect(harness.splits.isSplitStatusKnown('parent_1'), isFalse);

      fail = false;
      await tester.tap(find.byKey(const Key('split-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Split entries'), findsOneWidget);
      expect(harness.splits.isSplitStatusKnown('parent_1'), isTrue);
    });

    testWidgets('offers a retry instead of spinning when the session expired',
        (tester) async {
      await useTallView(tester);
      final harness = _Harness(token: null);
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text("Couldn't load split details."), findsOneWidget);
      expect(find.byKey(const Key('split-retry')), findsOneWidget);
      expect(harness.splits.isSplitStatusKnown('parent_1'), isFalse);
      expect(harness.requests, isEmpty);
    });

    testWidgets('retries the lookup after reconnecting', (tester) async {
      await useTallView(tester);
      final harness = _Harness(online: false);
      await tester.pumpWidget(harness.wrap(screen(transaction('parent_1'))));
      await tester.pumpAndSettle();
      expect(harness.requests, isEmpty);

      harness.connectivity.setOnline(true);
      await tester.pumpAndSettle();

      expect(harness.requests, hasLength(1));
      expect(find.text('Split entries'), findsOneWidget);
    });
  });

  group('TransactionSplitsProvider', () {
    test('notifies listeners when connectivity changes', () {
      final harness = _Harness(online: false);
      var notified = 0;
      harness.splits.addListener(() => notified++);

      harness.connectivity.setOnline(true);
      expect(notified, 1);
      expect(harness.splits.isOnline, isTrue);

      harness.splits.dispose();
      harness.connectivity.setOnline(false);
      expect(notified, 1);
    });

    test('a failed lookup does not lock editing; success records membership',
        () async {
      final harness = _Harness(
        handler: (_) async => http.Response('{"error":"boom"}', 500),
      );
      expect(harness.splits.isSplitStatusKnown('child_1'), isFalse);
      await harness.splits
          .loadSplit(accessToken: 'token', transactionId: 'child_1');
      expect(harness.splits.isSplitStatusKnown('child_1'), isFalse);
      expect(harness.splits.canEditAfterLookup('child_1'), isTrue);
      expect(harness.splits.isSplitChild('child_1'), isFalse);

      final ok = _Harness();
      await ok.splits.loadSplit(accessToken: 'token', transactionId: 'child_1');
      expect(ok.splits.isSplitStatusKnown('child_1'), isTrue);
      expect(ok.splits.isSplitStatusKnown('child_2'), isTrue);
      expect(ok.splits.isSplitChild('child_1'), isTrue);
    });

    test('hides session and network errors, keeps validation messages',
        () async {
      const rows = [SplitRowInput(name: 'A', amount: '100')];
      Future<String?> errorFor(http.Response response) async {
        final harness = _Harness(handler: (_) async => response);
        final result = await harness.splits.saveSplit(
          accessToken: 'token',
          transactionId: 'parent_1',
          rows: rows,
          replace: false,
        );
        expect(result.success, isFalse);
        return result.error;
      }

      expect(await errorFor(http.Response('{}', 401)), isNull);
      expect(
        await errorFor(http.Response(
          '{"error":"validation_failed","message":"Splits must sum to the '
          'transaction amount"}',
          422,
        )),
        contains('sum'),
      );

      final offline = _Harness(
        handler: (_) async => throw http.ClientException('reset'),
      );
      final unsplit = await offline.splits
          .unsplit(accessToken: 'token', transactionId: 'parent_1');
      expect(unsplit.success, isFalse);
      expect(unsplit.error, isNull);
    });
  });
}
