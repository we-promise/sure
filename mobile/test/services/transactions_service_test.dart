import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/services/transactions_service.dart';

void main() {
  group('TransactionsService', () {
    test(
      'sends idempotency fields when creating mobile transactions',
      () async {
        final service = TransactionsService(
          client: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/api/v1/transactions');
            expect(request.body, contains('"external_id":"local_123"'));
            expect(request.body, contains('"source":"sure_mobile"'));
            return http.Response(
              '{"id":"tx_1","account":{"id":"acct_1"},"name":"Coffee",'
              '"date":"2026-06-01","amount":"\$4.50","currency":"USD",'
              '"classification":"expense"}',
              201,
            );
          }),
        );

        final result = await service.createTransaction(
          accessToken: 'token',
          accountId: 'acct_1',
          name: 'Coffee',
          date: '2026-06-01',
          amount: '4.50',
          currency: 'USD',
          nature: 'expense',
          externalId: 'local_123',
          source: TransactionsService.mobileIdempotencySource,
        );

        expect(result['success'], true);
        expect(result['transaction'].id, 'tx_1');
      },
    );

    test('omits idempotency fields when creating regular transactions',
        () async {
      final service = TransactionsService(
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final transaction = payload['transaction'] as Map<String, dynamic>;

          expect(transaction.containsKey('external_id'), false);
          expect(transaction.containsKey('source'), false);

          return http.Response(
            '{"id":"tx_1","account":{"id":"acct_1"},"name":"Coffee",'
            '"date":"2026-06-01","amount":"\$4.50","currency":"USD",'
            '"classification":"expense"}',
            201,
          );
        }),
      );

      final result = await service.createTransaction(
        accessToken: 'token',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: '4.50',
        currency: 'USD',
        nature: 'expense',
      );

      expect(result['success'], true);
    });

    test('omits empty idempotency fields when creating transactions', () async {
      final service = TransactionsService(
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final transaction = payload['transaction'] as Map<String, dynamic>;

          expect(transaction.containsKey('external_id'), false);
          expect(transaction.containsKey('source'), false);

          return http.Response(
            '{"id":"tx_1","account":{"id":"acct_1"},"name":"Coffee",'
            '"date":"2026-06-01","amount":"\$4.50","currency":"USD",'
            '"classification":"expense"}',
            201,
          );
        }),
      );

      final result = await service.createTransaction(
        accessToken: 'token',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: '4.50',
        currency: 'USD',
        nature: 'expense',
        externalId: '',
        source: '',
      );

      expect(result['success'], true);
    });

    test('omits partial idempotency fields when creating transactions',
        () async {
      final service = TransactionsService(
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final transaction = payload['transaction'] as Map<String, dynamic>;

          expect(transaction.containsKey('external_id'), false);
          expect(transaction.containsKey('source'), false);

          return http.Response(
            '{"id":"tx_1","account":{"id":"acct_1"},"name":"Coffee",'
            '"date":"2026-06-01","amount":"\$4.50","currency":"USD",'
            '"classification":"expense"}',
            201,
          );
        }),
      );

      final result = await service.createTransaction(
        accessToken: 'token',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: '4.50',
        currency: 'USD',
        nature: 'expense',
        externalId: 'local_123',
      );

      expect(result['success'], true);
    });

    test('preserves field-level update errors', () async {
      final service = TransactionsService(
        client: MockClient((request) async {
          expect(request.method, 'PATCH');
          return http.Response(
            '{"message":"Transaction could not be updated",'
            '"errors":{"name":["is too long"],'
            '"notes":["contains unsupported characters"]}}',
            422,
          );
        }),
      );

      final result = await service.updateTransaction(
        accessToken: 'token',
        transactionId: 'tx_1',
        name: 'Coffee',
      );

      expect(result['success'], false);
      expect(
        result['error'],
        'Transaction could not be updated: Name is too long; Notes contains unsupported characters',
      );
    });

    test(
      'returns null transaction for empty successful update responses',
      () async {
        final service = TransactionsService(
          client: MockClient((request) async {
            expect(request.method, 'PATCH');
            return http.Response('', 204);
          }),
        );

        final result = await service.updateTransaction(
          accessToken: 'token',
          transactionId: 'tx_1',
          name: 'Coffee',
        );

        expect(result['success'], true);
        expect(result['transaction'], isNull);
      },
    );

    test('fetches one transaction after an empty update response', () async {
      var requestCount = 0;
      final service = TransactionsService(
        client: MockClient((request) async {
          requestCount += 1;
          expect(request.method, 'GET');
          return http.Response(
            '{"id":"tx_1","account":{"id":"acct_1"},"name":"Coffee",'
            '"date":"2026-06-01","amount":"\$4.50","currency":"USD",'
            '"classification":"expense"}',
            200,
          );
        }),
      );

      final result = await service.getTransaction(
        accessToken: 'token',
        transactionId: 'tx_1',
      );

      expect(requestCount, 1);
      expect(result['success'], true);
      expect(result['transaction'].name, 'Coffee');
      expect(result['transaction'].accountId, 'acct_1');
    });
  });
}
