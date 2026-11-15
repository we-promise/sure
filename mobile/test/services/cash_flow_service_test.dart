import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/cash_flow.dart';
import 'package:sure_mobile/services/cash_flow_service.dart';
import 'package:sure_mobile/services/transactions_service.dart';

import '../support/cash_flow_fixture.dart';

void main() {
  final range =
      CashFlowDateRange(DateTime(2026, 10, 1), DateTime(2026, 10, 19));

  group('CashFlowService', () {
    test('requests the sankey view for an explicit date range', () async {
      late Uri requested;
      final service = CashFlowService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(cashFlowSankeyFixture, 200);
        }),
      );

      final result =
          await service.getCashFlow(accessToken: 'token', range: range);

      expect(requested.path, '/api/v1/cash_flow');
      expect(requested.queryParameters, {
        'view': 'sankey',
        'start_date': '2026-10-01',
        'end_date': '2026-10-19',
      });
      expect(result['success'], isTrue);
      final report = result['report'] as CashFlowReport;
      expect(report.expenseCategories, hasLength(3));
    });

    test('maps 401 to unauthorized', () async {
      final service = CashFlowService(
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      final result =
          await service.getCashFlow(accessToken: 'token', range: range);
      expect(result, {'success': false, 'error': 'unauthorized'});
    });

    test('surfaces the API validation message on 422', () async {
      final service = CashFlowService(
        client: MockClient((_) async => http.Response(
              '{"error":"invalid_period","message":"Date ranges require view=sankey"}',
              422,
            )),
      );
      final result =
          await service.getCashFlow(accessToken: 'token', range: range);
      expect(result['success'], isFalse);
      expect(result['error'], 'Date ranges require view=sankey');
    });

    test('returns a generic error on network failure', () async {
      final service = CashFlowService(
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      final result =
          await service.getCashFlow(accessToken: 'token', range: range);
      expect(result['success'], isFalse);
      expect(
        result['error'],
        'Unable to load cash flow. Please try again later.',
      );
    });

    test('reads the family month start day', () async {
      late Uri requested;
      final service = CashFlowService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response('{"month_start_day":15}', 200);
        }),
      );
      final result = await service.getMonthStartDay(accessToken: 'token');
      expect(requested.path, '/api/v1/family_settings');
      expect(result, {'success': true, 'month_start_day': 15});
    });

    test('maps a family settings 401 to unauthorized', () async {
      final service = CashFlowService(
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      final result = await service.getMonthStartDay(accessToken: 'token');
      expect(result, {'success': false, 'error': 'unauthorized'});
    });

    test('rejects a missing or out-of-range month start day', () async {
      for (final body in [
        '{}',
        '{"month_start_day":0}',
        '{"month_start_day":29}',
        '{"month_start_day":"15"}'
      ]) {
        final service = CashFlowService(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        final result = await service.getMonthStartDay(accessToken: 'token');
        expect(result['success'], isFalse, reason: body);
        expect(result['error'], 'Failed to load family settings');
      }
    });

    test('close() leaves an injected client open', () async {
      final client = _TrackingClient();
      CashFlowService(client: client).close();
      expect(client.closed, isFalse);
    });
  });

  test('TransactionsService filters by period and repeated category ids',
      () async {
    late Uri requested;
    final service = TransactionsService(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          '{"transactions":[],"pagination":{"page":1,"per_page":50,'
          '"total_count":0,"total_pages":0}}',
          200,
        );
      }),
    );

    final result = await service.getTransactions(
      accessToken: 'token',
      page: 1,
      perPage: 50,
      startDate: '2026-10-01',
      endDate: '2026-10-19',
      categoryIds: const ['cat_food', 'cat_groceries'],
    );

    expect(result['success'], isTrue);
    expect(requested.queryParameters['start_date'], '2026-10-01');
    expect(requested.queryParameters['end_date'], '2026-10-19');
    expect(requested.queryParametersAll['category_ids[]'],
        ['cat_food', 'cat_groceries']);
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => closed = true;
}
