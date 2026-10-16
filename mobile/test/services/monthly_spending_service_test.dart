import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/monthly_spending.dart';
import 'package:sure_mobile/services/monthly_spending_service.dart';
import 'package:sure_mobile/services/api_config.dart';
import '../support/monthly_spending_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('selection is isolated by server and user and preserves explicit none',
      () async {
    const selection = MonthlySpendingSelection(
        period: 'last_twelve', accountIds: [], categoryIds: ['food']);
    await MonthlySpendingPreferences.save('server-a:user-a', selection);
    expect(await MonthlySpendingPreferences.load('server-b:user-a'), isNull);
    expect(await MonthlySpendingPreferences.load('server-a:user-b'), isNull);
    final restored =
        (await MonthlySpendingPreferences.load('server-a:user-a'))!;
    expect(restored.accountIds, isEmpty);
    expect(restored.categoryIds, ['food']);
    expect(restored.resolved(DateTime(2026, 1)).from, isNull);
    expect(restored.resolved(DateTime(2026, 1)).query['account_ids[]'], ['']);
  });
  test('rolling year follows January while custom dates stay fixed', () {
    const rolling = MonthlySpendingSelection(
        period: 'this_year', from: '2025-01-01', to: '2025-12-01');
    expect(rolling.resolved(DateTime(2026, 1)).from, '2026-01-01');
    expect(rolling.resolved(DateTime(2026, 1)).to, '2026-01-01');
    const custom = MonthlySpendingSelection(
        period: 'custom', from: '2025-02-01', to: '2025-04-01');
    expect(custom.resolved(DateTime(2026, 1)).from, '2025-02-01');
  });
  test('corrupt saved settings do not break Home', () async {
    SharedPreferences.setMockInitialValues(
        {'monthly_spending:server:user': 'invalid'});
    expect(await MonthlySpendingPreferences.load('server:user'), isNull);
  });
  test('visibility is isolated by user/server and does not clear filters',
      () async {
    await MonthlySpendingPreferences.save(
        'a:one', const MonthlySpendingSelection(categoryIds: []));
    await MonthlySpendingPreferences.setVisible('a:one', false);
    expect(await MonthlySpendingPreferences.visible('a:one'), false);
    expect(await MonthlySpendingPreferences.visible('b:one'), true);
    expect(await MonthlySpendingPreferences.visible('a:two'), true);
    expect(
        (await MonthlySpendingPreferences.load('a:one'))!.categoryIds, isEmpty);
  });

  test('preserves empty filter selection and trusts server monthly totals',
      () async {
    final service = MonthlySpendingService(client: MockClient((request) async {
      expect(request.url.path, '/api/v1/cash_flow');
      expect(request.url.queryParameters['view'], 'monthly_spending');
      expect(request.url.queryParametersAll['account_ids[]'], ['']);
      expect(request.url.queryParametersAll['category_ids[]'], ['food']);
      return http.Response(jsonEncode(monthlySpendingFixture()), 200);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(
            accountIds: [], categoryIds: ['food']));
    expect(result.status, MonthlySpendingStatus.ready);
    expect(result.data!.months.last.total, 30);
    expect(result.data!.months.last.partial, isTrue);
    service.dispose();
  });

  for (final (code, status) in [
    (401, MonthlySpendingStatus.unauthorized),
    (403, MonthlySpendingStatus.unavailable),
    (404, MonthlySpendingStatus.unavailable),
    (422, MonthlySpendingStatus.invalidSelection),
    (500, MonthlySpendingStatus.error)
  ]) {
    test('handles HTTP $code without stale totals', () async {
      final service = MonthlySpendingService(
          client: MockClient((_) async => http.Response('{}', code)));
      final result = await service.fetch(
          accessToken: 'test-token',
          selection: const MonthlySpendingSelection());
      expect(result.status, status);
      expect(result.data, isNull);
      service.dispose();
    });
  }

  test('current rolling year needs only one request', () async {
    var calls = 0;
    final service = MonthlySpendingService(client: MockClient((request) async {
      calls++;
      final data = monthlySpendingFixture();
      data['period']['from'] = '2025-01-01';
      return http.Response(jsonEncode(data), 200);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(period: 'this_year')
            .resolved(DateTime(2025, 1)));
    expect(result.status, MonthlySpendingStatus.ready);
    expect(calls, 1);
    service.dispose();
  });

  test('rolling year refresh follows a new server year instead of cached dates',
      () async {
    final queries = <Map<String, String>>[];
    final service = MonthlySpendingService(client: MockClient((request) async {
      queries.add(request.url.queryParameters);
      final data = monthlySpendingFixture();
      data['as_of'] = '2026-01-02';
      data['period']['from'] = request.url.queryParameters['from'];
      data['period']['to'] = request.url.queryParameters['to'];
      return http.Response(jsonEncode(data), 200);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(
            period: 'this_year',
            accountIds: ['a'],
            categoryIds: ['food']).resolved(DateTime(2025, 12)));
    expect(queries.length, 2);
    expect(queries.last['from'], '2026-01-01');
    expect(queries.last['to'], '2026-01-01');
    expect(result.data!.from, '2026-01-01');
    service.dispose();
  });

  test(
      'future device calendar recovers via server date without widening filters',
      () async {
    var calls = 0;
    final service = MonthlySpendingService(client: MockClient((request) async {
      calls++;
      expect(request.url.queryParametersAll['account_ids[]'], ['']);
      expect(request.url.queryParametersAll['category_ids[]'], ['food']);
      if (calls == 1) return http.Response('{}', 422);
      final data = monthlySpendingFixture(emptySelection: true);
      if (calls == 2) {
        expect(request.url.queryParameters.containsKey('from'), isFalse);
        expect(request.url.queryParameters.containsKey('to'), isFalse);
        data['period']['from'] = '2024-02-01';
      } else {
        expect(request.url.queryParameters['from'], '2025-01-01');
        expect(request.url.queryParameters['to'], '2025-01-01');
        data['period']['from'] = '2025-01-01';
      }
      return http.Response(jsonEncode(data), 200);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(
            period: 'this_year',
            accountIds: [],
            categoryIds: ['food']).resolved(DateTime(2025, 5)));
    expect(calls, 3);
    expect(result.status, MonthlySpendingStatus.ready);
    expect(result.data!.accountIds, isEmpty);
    service.dispose();
  });

  test('unavailable rolling filter IDs remain an error after a bounded retry',
      () async {
    var calls = 0;
    final service = MonthlySpendingService(client: MockClient((request) async {
      calls++;
      expect(request.url.queryParametersAll['account_ids[]'], ['deleted']);
      return http.Response('{}', 422);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(
            period: 'this_year',
            accountIds: ['deleted']).resolved(DateTime(2025, 1)));
    expect(calls, 2);
    expect(result.status, MonthlySpendingStatus.invalidSelection);
    expect(result.data, isNull);
    service.dispose();
  });

  test('calendar retry keeps the original server and credentials', () async {
    final originalUrl = ApiConfig.baseUrl;
    final originalHeaders = ApiConfig.getAuthHeaders('test-token');
    addTearDown(() {
      ApiConfig.setBaseUrl(originalUrl);
      final key = originalHeaders['X-Api-Key'];
      if (key == null) {
        ApiConfig.clearApiKeyAuth();
      } else {
        ApiConfig.setApiKeyAuth(key);
      }
    });
    ApiConfig.setBaseUrl('https://server-a.invalid');
    ApiConfig.setApiKeyAuth('server-a-key');
    var calls = 0;
    final service = MonthlySpendingService(client: MockClient((request) async {
      calls++;
      expect(request.url.host, 'server-a.invalid');
      expect(request.headers['X-Api-Key'], 'server-a-key');
      final data = monthlySpendingFixture();
      data['as_of'] = '2026-01-02';
      data['period']['from'] = request.url.queryParameters['from'];
      data['period']['to'] = request.url.queryParameters['to'];
      ApiConfig.setBaseUrl('https://server-b.invalid');
      ApiConfig.setApiKeyAuth('server-b-key');
      return http.Response(jsonEncode(data), 200);
    }));
    final result = await service.fetch(
        accessToken: 'test-token',
        selection: const MonthlySpendingSelection(period: 'this_year')
            .resolved(DateTime(2025, 12)));
    expect(calls, 2);
    expect(result.status, MonthlySpendingStatus.ready);
    service.dispose();
  });

  test('malformed or offline responses become retryable errors', () async {
    for (final client in [
      MockClient((_) async => http.Response('{}', 200)),
      MockClient((_) async => throw const FormatException())
    ]) {
      final service = MonthlySpendingService(client: client);
      expect(
          (await service.fetch(
                  accessToken: 'test-token',
                  selection: const MonthlySpendingSelection()))
              .status,
          MonthlySpendingStatus.error);
      service.dispose();
    }
  });
  test('older cash-flow server without this view hides the preview', () async {
    final service = MonthlySpendingService(
        client: MockClient(
            (_) async => http.Response('{"error":"invalid_view"}', 422)));
    final result = await service.fetch(
        accessToken: 'test', selection: const MonthlySpendingSelection());
    expect(result.status, MonthlySpendingStatus.unavailable);
    service.dispose();
  });
}
