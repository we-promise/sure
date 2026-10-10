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
    final endpoint = Uri.parse('${ApiConfig.baseUrl}/api/v1/monthly_spending');
    final headers = ApiConfig.getAuthHeaders(accessToken);
    var result = await _fetch(endpoint, headers, selection);
    if (selection.period != 'this_year' &&
        selection.period != 'previous_year') {
      return result;
    }
    if (result.status == MonthlySpendingStatus.invalidSelection) {
      // The device may already be in a month the family's server has not
      // reached. Ask for its default period, preserving every selected ID.
      result = await _fetch(
          endpoint,
          headers,
          MonthlySpendingSelection(
              accountIds: selection.accountIds,
              categoryIds: selection.categoryIds));
    }
    final data = result.data;
    if (result.status != MonthlySpendingStatus.ready || data == null) {
      return result;
    }
    final current = selection.resolved(data.asOf);
    if (data.from == current.from && data.to == current.to) return result;
    // Refresh a rolling year using the freshly returned server date, rather
    // than a cached response or the device's calendar. Usually no retry is needed.
    return _fetch(endpoint, headers, current);
  }

  Future<MonthlySpendingResult> _fetch(Uri endpoint,
      Map<String, String> headers, MonthlySpendingSelection selection) async {
    final uri = endpoint.replace(queryParameters: selection.query);
    try {
      final response = await _client
          .get(uri, headers: headers)
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
