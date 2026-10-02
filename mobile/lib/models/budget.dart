import '../utils/json_parsing.dart';

/// Amounts stay in the API's integer minor units. Display strings come from
/// Rails so currencies with zero or three decimal places are not divided by 100.
class BudgetAmounts {
  final String? budgeted;
  final int? budgetedMinor;
  final String? spent;
  final int? spentMinor;
  final String? remaining;
  final int? remainingMinor;
  final String? rollover;
  final int? rolloverMinor;

  BudgetAmounts.fromJson(Map<String, dynamic> json, {bool category = false})
      : budgeted = JsonParsing.parseString(
            json[category ? 'display_budgeted_spending' : 'budgeted_spending']),
        budgetedMinor = JsonParsing.parseInt(json[category
            ? 'display_budgeted_spending_cents'
            : 'budgeted_spending_cents']),
        spent = JsonParsing.parseString(json['actual_spending']),
        spentMinor = JsonParsing.parseInt(json['actual_spending_cents']),
        remaining = JsonParsing.parseString(json['available_to_spend']),
        remainingMinor = JsonParsing.parseInt(json['available_to_spend_cents']),
        rollover = JsonParsing.parseString(json['rolled_over_amount']),
        rolloverMinor = JsonParsing.parseInt(json['rolled_over_amount_cents']);

  bool get overBudget => remainingMinor != null && remainingMinor! < 0;

  double? get progress {
    if (budgetedMinor == null || spentMinor == null) return null;
    final capacity = budgetedMinor! + (rolloverMinor ?? 0);
    if (capacity <= 0) return spentMinor! > 0 ? 1 : 0;
    return (spentMinor! / capacity).clamp(0.0, 1.0);
  }
}

class Budget {
  final String id;
  final String name;
  final String currency;
  final DateTime startDate;
  final DateTime endDate;
  final bool initialized;
  final BudgetAmounts amounts;

  Budget.fromJson(Map<String, dynamic> json)
      : id = JsonParsing.parseRequiredString(json['id'], 'id'),
        name = JsonParsing.parseRequiredString(json['name'], 'name'),
        currency =
            JsonParsing.parseRequiredString(json['currency'], 'currency'),
        startDate =
            JsonParsing.parseRequiredDateTime(json['start_date'], 'start_date'),
        endDate =
            JsonParsing.parseRequiredDateTime(json['end_date'], 'end_date'),
        initialized = json['initialized'] == true,
        amounts = BudgetAmounts.fromJson(json);
}

class BudgetCategory {
  final String id;
  final String name;
  final bool inheritsParentBudget;
  final BudgetAmounts amounts;

  BudgetCategory.fromJson(Map<String, dynamic> json)
      : id = JsonParsing.parseRequiredString(json['id'], 'id'),
        name = JsonParsing.parseRequiredString(
            _categoryObject(json)['name'], 'category.name'),
        inheritsParentBudget = json['inherits_parent_budget'] == true,
        amounts = BudgetAmounts.fromJson(json, category: true);

  static Map<String, dynamic> _categoryObject(Map<String, dynamic> json) {
    final category = json['category'];
    if (category is! Map<String, dynamic>) {
      throw const FormatException('Invalid category object');
    }
    return category;
  }
}
