import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/monthly_spending.dart';
import 'api_config.dart';

enum MonthlySpendingStatus {
  ready,
  unavailable,
  unauthorized,
  error,
  invalidSelection
}

class MonthlySpendingResult {
  const MonthlySpendingResult(this.status, [this.data]);
  final MonthlySpendingStatus status;
  final MonthlySpendingData? data;
}

typedef MonthlySpendingLoader = Future<MonthlySpendingResult> Function(
    MonthlySpendingSelection selection);

class MonthlySpendingService {
  MonthlySpendingService({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;

  void dispose() => _client.close();

  Future<MonthlySpendingResult> fetch(
      {required String accessToken,
      required MonthlySpendingSelection selection}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/v1/monthly_spending')
        .replace(queryParameters: selection.query);
    try {
      final response = await _client
          .get(uri, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));
      switch (response.statusCode) {
        case 200:
          return MonthlySpendingResult(MonthlySpendingStatus.ready,
              MonthlySpendingData.fromJson(jsonDecode(response.body)));
        case 401:
          return const MonthlySpendingResult(
              MonthlySpendingStatus.unauthorized);
        case 403:
        case 404:
          // Preview off or an older server: the rest of Home still works.
          return const MonthlySpendingResult(MonthlySpendingStatus.unavailable);
        case 422:
          return const MonthlySpendingResult(
              MonthlySpendingStatus.invalidSelection);
        default:
          return const MonthlySpendingResult(MonthlySpendingStatus.error);
      }
    } catch (_) {
      return const MonthlySpendingResult(MonthlySpendingStatus.error);
    }
  }
}
