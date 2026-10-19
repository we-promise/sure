import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/budget.dart';

import '../support/budget_fixtures.dart';

void main() {
  group('Budget', () {
    test('parses show payload with derived amounts', () {
      final budget = Budget.fromJson(budgetJson());

      expect(budget.id, 'budget_oct');
      expect(budget.startDate, DateTime(2026, 10, 1));
      expect(budget.name, 'October 2026');
      expect(budget.budgetedSpending, r'$2,000.00');
      expect(budget.actualSpendingCents, 150000);
      expect(budget.availableToSpend, r'$500.00');
      expect(budget.hasDerivedAmounts, isTrue);
      expect(budget.isOverBudget, isFalse);
      expect(budget.spentFraction, closeTo(0.75, 0.0001));
    });

    test('index payload has no derived amounts', () {
      final json = budgetJson()..remove('actual_spending_cents');
      expect(Budget.fromJson(json).hasDerivedAmounts, isFalse);
    });

    test('uninitialized budget has null budgeted spending', () {
      final budget = Budget.fromJson(budgetJson(initialized: false));
      expect(budget.initialized, isFalse);
      expect(budget.budgetedSpending, isNull);
    });

    test('negative remaining is over budget', () {
      final budget = Budget.fromJson(
        budgetJson(actualCents: 250000, availableCents: -50000),
      );
      expect(budget.isOverBudget, isTrue);
      expect(budget.spentFraction, closeTo(1.25, 0.0001));
    });
  });

  group('BudgetCategory', () {
    BudgetCategory find(String id) => BudgetCategory.fromJson(
          octoberCategories().firstWhere((c) => c['id'] == id),
        );

    test('on track category near its limit', () {
      final food = find('bc_food');
      expect(food.isBudgeted, isTrue);
      expect(food.isOverBudget, isFalse);
      expect(food.spentFraction, closeTo(0.95, 0.0001));
      expect(food.isNearLimit, isTrue);
      expect(food.isVisible, isTrue);
    });

    test('subcategory with its own limit can be over budget', () {
      final groceries = find('bc_groceries');
      expect(groceries.subcategory, isTrue);
      expect(groceries.parentCategoryId, 'cat_food');
      expect(groceries.isOverBudget, isTrue);
      expect(groceries.isNearLimit, isFalse);
      expect(groceries.spentFraction, closeTo(1.3, 0.0001));
    });

    test('shared subcategory measures against the parent allocation', () {
      final restaurants = find('bc_restaurants');
      expect(restaurants.inheritsParentBudget, isTrue);
      expect(restaurants.isOverBudget, isFalse);
      expect(restaurants.spentFraction, closeTo(0.3, 0.0001));
    });

    test('rollover counts toward what there is to spend', () {
      final transport = find('bc_transport');
      expect(transport.effectiveBudgetCents, 35000);
      expect(transport.spentFraction, closeTo(12000 / 35000, 0.0001));
    });

    test('unbudgeted without spending is hidden, with spending is over', () {
      expect(find('bc_gifts').isVisible, isFalse);
      expect(find('bc_gifts').isOverBudget, isFalse);

      final spent = BudgetCategory.fromJson(
        budgetCategoryJson(
          id: 'bc_misc',
          categoryId: 'cat_misc',
          name: 'Misc',
          actualCents: 1000,
        ),
      );
      expect(spent.isVisible, isTrue);
      expect(spent.isOverBudget, isTrue);
    });

    test('shared subcategory without spending is hidden', () {
      final idle = BudgetCategory.fromJson(
        budgetCategoryJson(
          id: 'bc_idle',
          categoryId: 'cat_idle',
          name: 'Idle',
          parentId: 'cat_food',
          inheritsParent: true,
          displayBudgetedCents: 80000,
          availableCents: 0,
        ),
      );
      expect(idle.isVisible, isFalse);
    });
  });

  group('BudgetCategoryGroup.build', () {
    test('nests subcategories under their parent in server order', () {
      final groups = BudgetCategoryGroup.build(
        octoberCategories().map(BudgetCategory.fromJson).toList(),
      );

      expect(groups.map((g) => g.parent.name), ['Food', 'Gifts', 'Transport']);
      expect(
        groups.first.children.map((c) => c.name),
        ['Groceries', 'Restaurants'],
      );
      expect(
        groups.first.categoryIds,
        ['cat_food', 'cat_groceries', 'cat_restaurants'],
      );
      expect(groups.first.hasOverBudget, isTrue);
    });

    test('orphan subcategory becomes its own group', () {
      final groups = BudgetCategoryGroup.build([
        BudgetCategory.fromJson(
          budgetCategoryJson(
            id: 'bc_orphan',
            categoryId: 'cat_orphan',
            name: 'Orphan',
            parentId: 'cat_missing',
            budgetedCents: 100,
          ),
        ),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.parent.name, 'Orphan');
    });
  });

  test('spentFractionFor follows the web zero-budget rules', () {
    expect(spentFractionFor(actual: 0, total: 0), 0);
    expect(spentFractionFor(actual: 10, total: 0), 1);
    expect(spentFractionFor(actual: 0, total: 100), 0);
    expect(spentFractionFor(actual: 50, total: 100), 0.5);
  });
}
