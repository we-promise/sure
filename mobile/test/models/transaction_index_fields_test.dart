import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/offline_transaction.dart';
import 'package:sure_mobile/models/transaction.dart';
import 'package:sure_mobile/providers/transaction_splits_provider.dart';
import 'package:sure_mobile/services/transaction_splits_service.dart';
import 'package:sure_mobile/utils/split_list_grouping.dart';
import 'package:sure_mobile/widgets/transaction_split_section.dart';

Map<String, dynamic> _json({
  String amount = r'$100.13',
  String classification = 'expense',
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': 'tx_1',
      'account': {'id': 'acct_1'},
      'name': 'Groceries',
      'date': '2026-06-01',
      'amount': amount,
      'currency': 'USD',
      'classification': classification,
      ...extra,
    };

class _Lookups implements SplitLookup {
  _Lookups({this.parents = const {}, this.known = const {}});

  final Map<String, List<String>> parents;
  final Set<String> known;

  @override
  List<String>? childIdsFor(String parentId) => parents[parentId];

  @override
  bool isSplitParent(String transactionId) =>
      parents.containsKey(transactionId);

  @override
  bool isSplitStatusKnown(String transactionId) =>
      known.contains(transactionId) || parents.containsKey(transactionId);
}

void main() {
  group('Transaction index fields (#4422)', () {
    test('parses amount_decimal, kind, excluded and split_parent', () {
      final t = Transaction.fromJson(_json(extra: {
        'amount_decimal': '100.1250',
        'kind': 'loan_payment',
        'excluded': true,
        'split_parent': true,
      }));

      expect(t.amountDecimal, '100.1250');
      expect(t.kind, 'loan_payment');
      expect(t.excluded, isTrue);
      expect(t.splitParent, isTrue);
    });

    test('leaves the fields null for servers that do not send them', () {
      final t = Transaction.fromJson(_json());

      expect(t.amountDecimal, isNull);
      expect(t.kind, isNull);
      expect(t.excluded, isNull);
      expect(t.splitParent, isNull);
    });

    test('does not send the read-only fields back to the API', () {
      final t = Transaction.fromJson(_json(extra: {
        'amount_decimal': '1.5',
        'kind': 'standard',
        'excluded': false,
        'split_parent': false,
      }));

      expect(
        t.toJson().keys,
        isNot(anyOf(contains('amount_decimal'), contains('kind'),
            contains('excluded'), contains('split_parent'))),
      );
    });

    test('round-trips through the offline database map', () {
      final offline = OfflineTransaction.fromTransaction(
        Transaction.fromJson(_json(extra: {
          'amount_decimal': '-40.5',
          'kind': 'standard',
          'excluded': true,
          'split_parent': true,
        })),
        localId: 'local_1',
      );

      final map = offline.toDatabaseMap();
      expect(map['amount_decimal'], '-40.5');
      expect(map['kind'], 'standard');
      expect(map['excluded'], 1);
      expect(map['split_parent'], 1);

      final restored = OfflineTransaction.fromDatabaseMap(map);
      expect(restored.amountDecimal, '-40.5');
      expect(restored.kind, 'standard');
      expect(restored.excluded, isTrue);
      expect(restored.splitParent, isTrue);
      expect(restored.toTransaction().splitParent, isTrue);
    });

    test('reads rows cached before the columns existed as unknown', () {
      final map = OfflineTransaction.fromTransaction(
        Transaction.fromJson(_json()),
        localId: 'local_1',
      ).toDatabaseMap()
        ..remove('amount_decimal')
        ..remove('kind')
        ..remove('excluded')
        ..remove('split_parent');

      final restored = OfflineTransaction.fromDatabaseMap(map);
      expect(restored.amountDecimal, isNull);
      expect(restored.splitParent, isNull);
    });

    test('a server sync updates the split flag, e.g. after an unsplit', () {
      final cached = OfflineTransaction.fromTransaction(
        Transaction.fromJson(_json(extra: {
          'amount_decimal': '100.13',
          'split_parent': true,
          'excluded': true,
        })),
        localId: 'local_1',
      );

      final merged = cached.mergeServerTransaction(
        Transaction.fromJson(_json(extra: {
          'amount_decimal': '100.13',
          'split_parent': false,
          'excluded': false,
        })),
        accountId: 'acct_1',
      );

      expect(merged.splitParent, isFalse);
      expect(merged.excluded, isFalse);
    });

    test('a changed amount drops a stale exact amount', () {
      final cached = OfflineTransaction.fromTransaction(
        Transaction.fromJson(_json(extra: {'amount_decimal': '100.13'})),
        localId: 'local_1',
      );

      // An older server sends no amount_decimal.
      final merged = cached.mergeServerTransaction(
        Transaction.fromJson(_json(amount: r'$90.00')),
        accountId: 'acct_1',
      );
      expect(merged.amountDecimal, isNull);

      expect(cached.copyWith(amount: r'$90.00').amountDecimal, isNull);
      expect(cached.copyWith(name: 'Renamed').amountDecimal, '100.13');
    });
  });

  group('splitTargetUnitsFor', () {
    test('seeds a new split from the exact stored amount', () {
      final t = Transaction.fromJson(_json(
        amount: r'$12.35',
        extra: {'amount_decimal': '12.3456'},
      ));

      // SplitMath units have 4 decimals: 12.3456, not the rounded 12.35.
      expect(splitTargetUnitsFor(t), BigInt.from(123456));
    });

    test('keeps the API sign: a negative amount is an inflow', () {
      final t = Transaction.fromJson(_json(
        amount: r'$40.50',
        classification: 'income',
        extra: {'amount_decimal': '-40.5'},
      ));

      expect(splitTargetUnitsFor(t), BigInt.from(-405000));
    });

    test('falls back to the display amount on older servers', () {
      final expense = Transaction.fromJson(_json(amount: r'$12.35'));
      final income = Transaction.fromJson(
        _json(amount: r'$40.50', classification: 'income'),
      );

      expect(splitTargetUnitsFor(expense), BigInt.from(123500));
      expect(splitTargetUnitsFor(income), BigInt.from(-405000));
    });
  });

  group('splitChildIdsForList', () {
    test('a flagged parent is grouped as a parent before its lookup', () {
      final ids = splitChildIdsForList(
        'p',
        splits: _Lookups(),
        flaggedParents: {'p'},
      );
      expect(ids, isEmpty);

      final entries = groupSplitEntries<String>(
        ['p', 'x'],
        idOf: (id) => id,
        childIdsOf: (id) => splitChildIdsForList(
          id,
          splits: _Lookups(),
          flaggedParents: {'p'},
        ),
        parentIdOf: (_) => null,
      );
      expect(entries.first.role, SplitRole.parent);
      expect(entries.last.role, SplitRole.none);
    });

    test('a looked-up split supplies the children', () {
      final ids = splitChildIdsForList(
        'p',
        splits: _Lookups(parents: {
          'p': ['c1', 'c2'],
        }),
        flaggedParents: const {},
      );
      expect(ids, ['c1', 'c2']);
    });

    test('a lookup that says "not split" wins over a stale flag', () {
      final ids = splitChildIdsForList(
        'p',
        splits: _Lookups(known: {'p'}),
        flaggedParents: {'p'},
      );
      expect(ids, isNull);
    });
  });

  group('TransactionSplitsProvider.loadFlaggedParents', () {
    test('looks up flagged parents one at a time, up to the limit', () async {
      final requested = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final provider = TransactionSplitsProvider(
        service: TransactionSplitsService(
          client: MockClient((request) async {
            inFlight++;
            maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
            requested.add(request.url.pathSegments.reversed.skip(1).first);
            await Future<void>.delayed(Duration.zero);
            inFlight--;
            return http.Response(
              jsonEncode({
                'error': 'not_found',
                'message': 'Transaction is not split',
              }),
              404,
            );
          }),
        ),
      );

      await provider.loadFlaggedParents(
        accessToken: 'token',
        transactionIds: ['a', 'b', 'c'],
        limit: 2,
      );

      expect(requested, ['a', 'b']);
      expect(maxInFlight, 1);
      expect(provider.isSplitStatusKnown('a'), isTrue);

      // Known rows are skipped on the next refresh.
      await provider.loadFlaggedParents(
        accessToken: 'token',
        transactionIds: ['a', 'b', 'c'],
      );
      expect(requested, ['a', 'b', 'c']);
    });

    test('does not retry a flagged parent whose lookup failed', () async {
      var calls = 0;
      final provider = TransactionSplitsProvider(
        service: TransactionSplitsService(
          client: MockClient((request) async {
            calls++;
            return http.Response('oops', 500);
          }),
        ),
      );

      await provider.loadFlaggedParents(
        accessToken: 'token',
        transactionIds: ['a'],
      );
      await provider.loadFlaggedParents(
        accessToken: 'token',
        transactionIds: ['a'],
      );

      expect(calls, 1);
      expect(provider.isSplitStatusKnown('a'), isFalse);

      provider.clear();
      await provider.loadFlaggedParents(
        accessToken: 'token',
        transactionIds: ['a'],
      );
      expect(calls, 2);
    });
  });
}
