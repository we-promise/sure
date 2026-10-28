import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/account.dart';
import 'package:sure_mobile/services/accounts_service.dart';

/// Serves `/api/v1/accounts` the way the API pages it: `per_page` capped at
/// 100, accounts named `Account 001`, `Account 002`, ... in order.
MockClient accountsClient({
  required int total,
  List<http.Request>? log,
  int? failOnPage,
}) {
  return MockClient((request) async {
    log?.add(request);
    final page = int.parse(request.url.queryParameters['page'] ?? '1');
    final perPage = int.parse(request.url.queryParameters['per_page'] ?? '25');
    if (page == failOnPage) {
      return http.Response(jsonEncode({'error': 'Server error'}), 500);
    }
    final first = (page - 1) * perPage;
    final last = (first + perPage).clamp(0, total);
    final accounts = [
      for (var i = first; i < last; i++)
        {
          'id': 'acct_$i',
          'name': 'Account ${(i + 1).toString().padLeft(3, '0')}',
          'balance': r'$10.00',
          'currency': 'USD',
          'classification': 'asset',
          'account_type': 'depository',
        },
    ];
    return http.Response(
      jsonEncode({
        'accounts': accounts,
        'pagination': {
          'page': page,
          'per_page': perPage,
          'total_count': total,
          'total_pages': (total / perPage).ceil(),
        },
      }),
      200,
    );
  });
}

void main() {
  group('AccountsService.getAllAccounts', () {
    test('returns every account of a family with more than one page of 25',
        () async {
      final requests = <http.Request>[];
      final service = AccountsService(
        client: accountsClient(total: 26, log: requests),
      );

      final result = await service.getAllAccounts(accessToken: 'token');

      expect(result['success'], isTrue);
      final accounts = result['accounts'] as List<Account>;
      expect(accounts, hasLength(26));
      expect(accounts.last.name, 'Account 026');
    });

    test('follows total_pages for a family with more than 100 accounts',
        () async {
      final requests = <http.Request>[];
      final service = AccountsService(
        client: accountsClient(total: 230, log: requests),
      );

      final result = await service.getAllAccounts(accessToken: 'token');

      final accounts = result['accounts'] as List<Account>;
      expect(accounts, hasLength(230));
      expect(accounts.map((a) => a.id).toSet(), hasLength(230));
      expect(
        requests.map((r) => r.url.queryParameters['page']),
        ['1', '2', '3'],
      );
      expect(requests.first.url.queryParameters['per_page'], '100');
    });

    test('makes a single request when everything fits on one page', () async {
      final requests = <http.Request>[];
      final service = AccountsService(
        client: accountsClient(total: 3, log: requests),
      );

      final result = await service.getAllAccounts(accessToken: 'token');

      expect(result['accounts'] as List<Account>, hasLength(3));
      expect(requests, hasLength(1));
    });

    test('fails without partial accounts when a later page fails', () async {
      final service = AccountsService(
        client: accountsClient(total: 230, failOnPage: 2),
      );

      final result = await service.getAllAccounts(accessToken: 'token');

      expect(result['success'], isFalse);
      expect(result['error'], 'Server error');
      expect(result.containsKey('accounts'), isFalse);
    });

    test('stops instead of following an absurd total_pages', () async {
      final service = AccountsService(
        client: accountsClient(total: AccountsService.maxPages * 100 + 1),
      );

      final result = await service.getAllAccounts(accessToken: 'token');

      expect(result['success'], isFalse);
      expect(result.containsKey('accounts'), isFalse);
    });
  });
}
