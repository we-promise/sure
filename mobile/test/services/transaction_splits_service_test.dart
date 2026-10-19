import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/transaction_split.dart';
import 'package:sure_mobile/services/transaction_splits_service.dart';

const splitJson = '''
{
  "transaction_id": "parent_1",
  "amount": "\$100.00",
  "amount_decimal": "100.0",
  "amount_cents": 10000,
  "currency": "USD",
  "children": [
    {
      "id": "child_1", "name": "Groceries", "amount": "\$60.00",
      "currency": "USD", "date": "2026-06-01", "classification": "expense",
      "account": {"id": "acct_1"},
      "category": {"id": "cat_food", "name": "Food"},
      "amount_decimal": "60.0", "excluded": false
    },
    {
      "id": "child_2", "name": "Household", "amount": "\$40.00",
      "currency": "USD", "date": "2026-06-01", "classification": "expense",
      "account": {"id": "acct_1"}, "category": null,
      "amount_decimal": "40.0", "excluded": true
    }
  ]
}
''';

void main() {
  group('TransactionSplitsService', () {
    test('GET parses the split and its children', () async {
      final service = TransactionSplitsService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/transactions/child_1/split');
          return http.Response(splitJson, 200);
        }),
      );

      final result = await service.getSplit(
        accessToken: 'token',
        transactionId: 'child_1',
      );

      expect(result['success'], isTrue);
      final split = result['split'] as TransactionSplit;
      expect(split.transactionId, 'parent_1');
      expect(split.amountUnits, BigInt.from(1000000));
      expect(split.childIds, ['child_1', 'child_2']);
      expect(split.children.first.categoryName, 'Food');
      expect(split.children.last.excluded, isTrue);
      expect(split.children.last.categoryId, isNull);
    });

    test('GET treats 404 as "not split" rather than an error', () async {
      final service = TransactionSplitsService(
        client: MockClient(
          (_) async => http.Response(
            '{"error":"not_found","message":"Transaction is not split"}',
            404,
          ),
        ),
      );

      final result = await service.getSplit(
        accessToken: 'token',
        transactionId: 'tx_1',
      );

      expect(result['success'], isTrue);
      expect(result['split'], isNull);
    });

    test('POST and PATCH send the split payload', () async {
      final seen = <String>[];
      final service = TransactionSplitsService(
        client: MockClient((request) async {
          seen.add(request.method);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final splits = (body['split'] as Map)['splits'] as List;
          expect(splits, hasLength(2));
          expect(splits.first, {
            'name': 'Groceries',
            'amount': '60.0000',
            'category_id': 'cat_food',
          });
          expect(splits.last['excluded'], isTrue);
          return http.Response(
            splitJson,
            request.method == 'POST' ? 201 : 200,
          );
        }),
      );

      const rows = [
        SplitRowInput(
          name: 'Groceries',
          amount: '60.0000',
          categoryId: 'cat_food',
        ),
        SplitRowInput(name: 'Household', amount: '40.0000', excluded: true),
      ];

      final created = await service.createSplit(
        accessToken: 'token',
        transactionId: 'parent_1',
        rows: rows,
      );
      final updated = await service.updateSplit(
        accessToken: 'token',
        transactionId: 'parent_1',
        rows: rows,
      );

      expect(seen, ['POST', 'PATCH']);
      expect(created['success'], isTrue);
      expect(updated['split'], isA<TransactionSplit>());
    });

    test('surfaces validation messages from the API', () async {
      final service = TransactionSplitsService(
        client: MockClient(
          (_) async => http.Response(
            '{"error":"validation_failed",'
            '"message":"Transaction cannot be split",'
            '"errors":["Transaction is part of a transfer"]}',
            422,
          ),
        ),
      );

      final result = await service.createSplit(
        accessToken: 'token',
        transactionId: 'tx_1',
        rows: const [SplitRowInput(name: 'A', amount: '1')],
      );

      expect(result['success'], isFalse);
      expect(
        result['error'],
        'Transaction cannot be split: Transaction is part of a transfer',
      );
    });

    test('DELETE succeeds on 204', () async {
      final service = TransactionSplitsService(
        client: MockClient((request) async {
          expect(request.method, 'DELETE');
          return http.Response('', 204);
        }),
      );

      final result = await service.deleteSplit(
        accessToken: 'token',
        transactionId: 'parent_1',
      );

      expect(result['success'], isTrue);
    });
  });
}
