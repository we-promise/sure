// Synthetic data only. List payloads deliberately omit derived amounts, as
// app/views/api/v1/{budgets,budget_categories}/index.json.jbuilder does.
Map<String, dynamic> budgetJson({bool detail = false}) => {
      'id': 'budget-1',
      'name': 'September budget',
      'currency': 'USD',
      'start_date': '2026-09-01',
      'end_date': '2026-09-30',
      'initialized': true,
      'budgeted_spending': r'$1,000.00',
      'budgeted_spending_cents': 100000,
      if (detail) ...{
        'actual_spending': r'$1,050.00',
        'actual_spending_cents': 105000,
        'available_to_spend': r'-$50.00',
        'available_to_spend_cents': -5000,
      },
    };

Map<String, dynamic> categoryJson({bool detail = false, bool shared = false}) =>
    {
      'id': 'category-1',
      'budget_id': 'budget-1',
      'currency': 'USD',
      'category': {'id': 'groceries', 'name': 'Groceries'},
      'inherits_parent_budget': shared,
      'display_budgeted_spending': r'$200.00',
      'display_budgeted_spending_cents': 20000,
      if (detail) ...{
        'actual_spending': r'$100.00',
        'actual_spending_cents': 10000,
        'rolled_over_amount': r'$50.00',
        'rolled_over_amount_cents': 5000,
        'available_to_spend': r'$150.00',
        'available_to_spend_cents': 15000,
      },
    };

Map<String, dynamic> budgetPage(
        {int page = 1, int totalPages = 1, bool empty = false}) =>
    {
      'budgets': empty ? [] : [budgetJson()],
      'pagination': {'page': page, 'total_pages': totalPages},
    };

Map<String, dynamic> categoryPage({int page = 1, int totalPages = 1}) => {
      'budget_categories': [categoryJson()],
      'pagination': {'page': page, 'total_pages': totalPages},
    };
