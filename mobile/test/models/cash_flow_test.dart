import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/cash_flow.dart';

import '../support/cash_flow_fixture.dart';

void main() {
  group('CashFlowPeriod.rangeFor', () {
    final today = DateTime(2026, 3, 15, 18, 30);

    test('matches the web Period presets', () {
      expect(
        CashFlowPeriod.currentMonth.rangeFor(today),
        CashFlowDateRange(DateTime(2026, 3, 1), DateTime(2026, 3, 15)),
      );
      expect(
        CashFlowPeriod.lastMonth.rangeFor(today),
        CashFlowDateRange(DateTime(2026, 2, 1), DateTime(2026, 2, 28)),
      );
      expect(
        CashFlowPeriod.last30Days.rangeFor(today),
        CashFlowDateRange(DateTime(2026, 2, 13), DateTime(2026, 3, 15)),
      );
      expect(
        CashFlowPeriod.last90Days.rangeFor(today),
        CashFlowDateRange(DateTime(2025, 12, 15), DateTime(2026, 3, 15)),
      );
      expect(
        CashFlowPeriod.currentYear.rangeFor(today),
        CashFlowDateRange(DateTime(2026, 1, 1), DateTime(2026, 3, 15)),
      );
      expect(
        CashFlowPeriod.last365Days.rangeFor(today),
        CashFlowDateRange(DateTime(2025, 3, 15), DateTime(2026, 3, 15)),
      );
    });

    test('last month wraps across the year boundary', () {
      expect(
        CashFlowPeriod.lastMonth.rangeFor(DateTime(2026, 1, 5)),
        CashFlowDateRange(DateTime(2025, 12, 1), DateTime(2025, 12, 31)),
      );
    });

    test('This month / Last month follow a custom month start day', () {
      // Family#custom_month_start_for: on or after the start day the custom
      // month began this calendar month, before it the previous one.
      expect(
        CashFlowPeriod.currentMonth.rangeFor(today, monthStartDay: 10),
        CashFlowDateRange(DateTime(2026, 3, 10), DateTime(2026, 4, 9)),
      );
      expect(
        CashFlowPeriod.lastMonth.rangeFor(today, monthStartDay: 10),
        CashFlowDateRange(DateTime(2026, 2, 10), DateTime(2026, 3, 9)),
      );
      expect(
        CashFlowPeriod.currentMonth.rangeFor(today, monthStartDay: 20),
        CashFlowDateRange(DateTime(2026, 2, 20), DateTime(2026, 3, 19)),
      );
      expect(
        CashFlowPeriod.lastMonth.rangeFor(today, monthStartDay: 20),
        CashFlowDateRange(DateTime(2026, 1, 20), DateTime(2026, 2, 19)),
      );
    });

    test('custom month start wraps across the year boundary', () {
      final jan = DateTime(2026, 1, 5);
      expect(
        CashFlowPeriod.currentMonth.rangeFor(jan, monthStartDay: 25),
        CashFlowDateRange(DateTime(2025, 12, 25), DateTime(2026, 1, 24)),
      );
      expect(
        CashFlowPeriod.lastMonth.rangeFor(jan, monthStartDay: 25),
        CashFlowDateRange(DateTime(2025, 11, 25), DateTime(2025, 12, 24)),
      );
    });

    test('rolling and yearly presets ignore the month start day', () {
      for (final period in [
        CashFlowPeriod.last30Days,
        CashFlowPeriod.last90Days,
        CashFlowPeriod.currentYear,
        CashFlowPeriod.last365Days,
      ]) {
        expect(
            period.rangeFor(today, monthStartDay: 10), period.rangeFor(today));
      }
      expect(
        CashFlowPeriod.currentMonth.rangeFor(today, monthStartDay: 1),
        CashFlowPeriod.currentMonth.rangeFor(today),
      );
    });

    test('formats ISO dates for the API', () {
      final range =
          CashFlowDateRange(DateTime(2026, 2, 3), DateTime(2026, 12, 31));
      expect(range.startIso, '2026-02-03');
      expect(range.endIso, '2026-12-31');
    });
  });

  group('CashFlowReport.fromJson', () {
    late CashFlowReport report;

    setUp(() {
      report = CashFlowReport.fromJson(
        jsonDecode(cashFlowSankeyFixture) as Map<String, dynamic>,
      );
    });

    test('reads totals, currency and period', () {
      expect(report.currency, 'USD');
      expect(report.startDate, DateTime(2026, 10, 1));
      expect(report.endDate, DateTime(2026, 10, 19));
      expect(report.income, 5000);
      expect(report.spending, 1500);
      expect(report.netSavings, 3500);
      expect(report.savingsRate, closeTo(70, 0.001));
    });

    test('ranks root categories per side, largest first', () {
      expect(
          report.incomeCategories.map((c) => c.name), ['Salary', 'Interest']);
      expect(report.expenseCategories.map((c) => c.name),
          ['Rent', 'Food & Drink', 'Uncategorized']);
      expect(report.expenseCategories.first.percentage, 66.7);
      expect(report.expenseCategories.first.color, '#4da568');
    });

    test('folds subcategories into their root for drill-down', () {
      final food =
          report.expenseCategories.firstWhere((c) => c.name == 'Food & Drink');
      expect(food.children.map((c) => c.name), ['Groceries']);
      expect(food.transactionCategoryIds, ['cat_food', 'cat_groceries']);
      expect(food.canDrillDown, isTrue);
    });

    test('synthetic buckets without a category id cannot drill down', () {
      final uncategorized = report.expenseCategories.last;
      expect(uncategorized.categoryId, isNull);
      expect(uncategorized.canDrillDown, isFalse);
    });

    test('drill-down includes subcategories listed on the other side', () {
      // Groceries refunds outweigh its spending, so the server lists it under
      // the income counterpart of Food & Drink instead of under its expenses.
      final json = jsonDecode(cashFlowSankeyFixture) as Map<String, dynamic>;
      final sankey = json['sankey'] as Map<String, dynamic>;
      final nodes = sankey['nodes'] as List;
      final links = sankey['links'] as List;
      nodes[4] = {
        'id': 'income_sub_cat_groceries',
        'name': 'Groceries',
        'kind': 'income',
        'value': '20.0',
        'percentage': '100.0',
        'category_id': 'cat_groceries',
        'color': '#e99537',
      };
      nodes.add({
        'id': 'income_cat_food',
        'name': 'Food & Drink',
        'kind': 'income',
        'value': '20.0',
        'percentage': '0.4',
        'category_id': 'cat_food',
        'color': '#e99537',
      });
      links[3] = {'source': 4, 'target': 8, 'value': '20.0'};
      links.add({'source': 8, 'target': 0, 'value': '20.0'});

      final r = CashFlowReport.fromJson(json);
      final expenseFood =
          r.expenseCategories.firstWhere((c) => c.name == 'Food & Drink');
      expect(expenseFood.children, isEmpty);
      expect(expenseFood.transactionCategoryIds, ['cat_food', 'cat_groceries']);
      final incomeFood =
          r.incomeCategories.firstWhere((c) => c.name == 'Food & Drink');
      expect(incomeFood.children.map((c) => c.name), ['Groceries']);
      expect(incomeFood.transactionCategoryIds, ['cat_food', 'cat_groceries']);
      final salary = r.incomeCategories.firstWhere((c) => c.name == 'Salary');
      expect(salary.transactionCategoryIds, ['cat_salary']);
    });

    test('nonpositive amounts are not listed', () {
      final json = jsonDecode(cashFlowSankeyFixture) as Map<String, dynamic>;
      final nodes = (json['sankey'] as Map)['nodes'] as List;
      for (final n in nodes) {
        if (n['name'] == 'Groceries') n['value'] = '-15.0';
        if (n['name'] == 'Interest') n['value'] = '-5.0';
      }
      final r = CashFlowReport.fromJson(json);
      expect(r.incomeCategories.map((c) => c.name), ['Salary']);
      final food =
          r.expenseCategories.firstWhere((c) => c.name == 'Food & Drink');
      expect(food.children, isEmpty);
    });

    test('structural nodes are not categories', () {
      final names = [
        ...report.incomeCategories.map((c) => c.name),
        ...report.expenseCategories.map((c) => c.name),
      ];
      expect(names, isNot(contains('Cash Flow')));
      expect(names, isNot(contains('Surplus')));
    });

    test('savings rate is null without positive income', () {
      final empty = CashFlowReport.fromJson({
        'currency': 'EUR',
        'period': {'start_date': '2026-01-01', 'end_date': '2026-01-31'},
        'sankey': {
          'income': '0',
          'spending': '0',
          'net_savings': '0',
          'nodes': <dynamic>[],
          'links': <dynamic>[],
        },
      });
      expect(empty.isEmpty, isTrue);
      expect(empty.savingsRate, isNull);
    });
  });
}
