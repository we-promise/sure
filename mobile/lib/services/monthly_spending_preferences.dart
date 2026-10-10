import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/monthly_spending.dart';

// Only filter IDs and period choices are stored, never financial results.
class MonthlySpendingPreferences {
  static Future<MonthlySpendingSelection?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('monthly_spending:$key');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return MonthlySpendingSelection(
        period: data['period'] as String?,
        from: data['from'] as String?,
        to: data['to'] as String?,
        accountIds: data['accounts'] == null
            ? null
            : List<String>.from(data['accounts']),
        categoryIds: data['categories'] == null
            ? null
            : List<String>.from(data['categories']),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
      String key, MonthlySpendingSelection selection) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'monthly_spending:$key',
          jsonEncode({
            'period': selection.period,
            'from': selection.from,
            'to': selection.to,
            'accounts': selection.accountIds,
            'categories': selection.categoryIds,
          }));
    } catch (_) {
      // A storage failure must not make the financial dashboard unavailable.
    }
  }
}
