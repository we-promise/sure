import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/budget.dart';

void main() {
  test('omitted list amounts remain unknown instead of becoming zero', () {
    final amounts = BudgetAmounts.fromJson({
      'budgeted_spending': '¥2,000',
      'budgeted_spending_cents': 2000,
    });
    expect(amounts.spent, isNull);
    expect(amounts.spentMinor, isNull);
    expect(amounts.remaining, isNull);
    expect(amounts.progress, isNull);
  });

  test(
      'uses integer minor units and preserves zero and three decimal currencies',
      () {
    for (final formatted in ['¥2,000', 'KWD 2.000']) {
      final amounts = BudgetAmounts.fromJson({
        'budgeted_spending': formatted,
        'budgeted_spending_cents': 2000,
        'actual_spending_cents': 500,
      });
      expect(amounts.budgeted, formatted);
      expect(amounts.progress, 0.25);
    }
  });

  test('category progress includes displayed rollover and clamps overspending',
      () {
    final amounts = BudgetAmounts.fromJson({
      'budgeted_spending_cents': 10000,
      'display_budgeted_spending_cents': 20000,
      'rolled_over_amount_cents': 5000,
      'actual_spending_cents': 30000,
      'available_to_spend_cents': -5000,
    }, category: true);
    expect(amounts.progress, 1);
    expect(amounts.overBudget, isTrue);
    final withCarry = BudgetAmounts.fromJson({
      'display_budgeted_spending_cents': 10000,
      'rolled_over_amount_cents': -2000,
      'actual_spending_cents': 4000,
    }, category: true);
    expect(withCarry.progress, 0.5);
  });

  test('zero budgets and refunds never produce invalid progress values', () {
    for (final spent in [0, -100, 100]) {
      final amounts = BudgetAmounts.fromJson({
        'budgeted_spending_cents': 0,
        'actual_spending_cents': spent,
      });
      expect(amounts.progress, spent > 0 ? 1 : 0);
    }
  });
}
