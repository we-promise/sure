import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/services/account_detail_service.dart';

void main() {
  group('AccountDetailService', () {
    test('fetches account metadata from the account show endpoint', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/accounts/acct_1');
          expect(request.headers['Authorization'], 'Bearer token');
          return http.Response(
            '{"id":"acct_1","name":"Brokerage","balance":"\$1,200.00",'
            '"balance_cents":120000,"cash_balance":"\$200.00",'
            '"cash_balance_cents":20000,"currency":"USD",'
            '"classification":"asset","account_type":"investment",'
            '"subtype":"brokerage","status":"active",'
            '"institution_name":"Sure Bank",'
            '"institution_domain":"sure.local",'
            '"created_at":"2026-06-01T00:00:00Z",'
            '"updated_at":"2026-06-02T00:00:00Z"}',
            200,
          );
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], true);
      expect(result['account'].cashBalance, r'$200.00');
      expect(result['account'].institutionName, 'Sure Bank');
    });

    test('returns unauthorized for account detail 401 responses', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/accounts/acct_1');
          expect(request.headers['Authorization'], 'Bearer token');
          return http.Response('{"error":"Unauthorized"}', 401);
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(result['error'], 'unauthorized');
    });

    test('encodes account ids in account detail paths', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), contains('/api/v1/accounts/acct%2F1'));
          return http.Response(
            '{"id":"acct/1","name":"Brokerage","balance":"\$1,200.00",'
            '"currency":"USD","classification":"asset",'
            '"account_type":"investment"}',
            200,
          );
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct/1',
      );

      expect(result['success'], true);
      expect(result['account'].id, 'acct/1');
    });

    test('returns fallback error for account detail 404 responses', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/accounts/missing');
          return http.Response('{"error":"Not found"}', 404);
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'missing',
      );

      expect(result['success'], false);
      expect(result['error'], 'Failed to fetch account');
    });

    test('returns fallback error for account detail server failures', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/accounts/acct_1');
          return http.Response('{"error":"Server error"}', 500);
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(result['error'], 'Failed to fetch account');
    });

    test('returns generic error for account detail network failures', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          throw http.ClientException('connection failed');
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(
        result['error'],
        'Unable to load account details. Please try again later.',
      );
    });

    test('returns generic error for malformed account detail JSON', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/accounts/acct_1');
          return http.Response('{', 200);
        }),
      );

      final result = await service.getAccountDetail(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(
        result['error'],
        'Unable to load account details. Please try again later.',
      );
    });

    test('fetches scoped balance history', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/balances');
          expect(request.url.queryParameters['account_id'], 'acct_1');
          expect(request.url.queryParameters['per_page'], '30');
          return http.Response(
            '{"balances":[{"id":"bal_1","date":"2026-06-01",'
            '"currency":"USD","balance":"\$1,200.00",'
            '"balance_cents":120000,"cash_balance":"\$200.00",'
            '"cash_balance_cents":20000}]}',
            200,
          );
        }),
      );

      final result = await service.getBalances(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], true);
      expect(result['balances'].single.balanceCents, 120000);
    });

    test('returns generic error for malformed balance dates', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/balances');
          return http.Response(
            '{"balances":[{"id":"bal_1","date":"not-a-date",'
            '"currency":"USD","balance":"\$1,200.00"}]}',
            200,
          );
        }),
      );

      final result = await service.getBalances(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(
        result['error'],
        'Unable to load balance history. Please try again later.',
      );
    });

    test('fetches scoped holdings for investment accounts', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/holdings');
          expect(request.url.queryParameters['account_id'], 'acct_1');
          return http.Response(
            '{"holdings":[{"id":"holding_1","date":"2026-06-01",'
            '"qty":"4.0","price":"\$10.00","amount":"\$40.00",'
            '"currency":"USD","security":{"ticker":"SURE",'
            '"name":"Sure Inc."}}]}',
            200,
          );
        }),
      );

      final result = await service.getHoldings(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], true);
      expect(result['holdings'].single.ticker, 'SURE');
      expect(result['holdings'].single.amount, r'$40.00');
    });

    test('returns generic error for malformed holding dates', () async {
      final service = AccountDetailService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/holdings');
          return http.Response(
            '{"holdings":[{"id":"holding_1","date":"not-a-date",'
            '"qty":"4.0","price":"\$10.00","amount":"\$40.00",'
            '"currency":"USD"}]}',
            200,
          );
        }),
      );

      final result = await service.getHoldings(
        accessToken: 'token',
        accountId: 'acct_1',
      );

      expect(result['success'], false);
      expect(
          result['error'], 'Unable to load holdings. Please try again later.');
    });
  });
}
