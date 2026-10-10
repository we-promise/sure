import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/monthly_spending.dart';
import 'package:sure_mobile/services/monthly_spending_service.dart';
import '../support/monthly_spending_fixture.dart';

void main() {
  test('preserves empty filter selection and trusts server monthly totals',
      () async {
    final service = MonthlySpendingService(client: MockClient((request) async {
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
}
