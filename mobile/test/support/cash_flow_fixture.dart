/// A `GET /api/v1/cash_flow?view=sankey` response shaped like
/// `IncomeStatement::Sankey#as_json`: income roots -> Cash Flow -> expense
/// roots -> expense subcategories, balanced by a Surplus node.
const String cashFlowSankeyFixture = '''
{
  "as_of": "2026-10-19",
  "time_zone": "America/New_York",
  "currency": "USD",
  "period": { "start_date": "2026-10-01", "end_date": "2026-10-19" },
  "sankey": {
    "basis": "net_by_category",
    "income": "5000.0",
    "spending": "1500.0",
    "invested": "0.0",
    "net_savings": "3500.0",
    "nodes": [
      { "id": "cash_flow_node", "name": "Cash Flow", "kind": "cash_flow", "value": "5000.0", "percentage": "100.0", "category_id": null, "filter_value": null, "color": null },
      { "id": "income_cat_salary", "name": "Salary", "kind": "income", "value": "4500.0", "percentage": "90.0", "category_id": "cat_salary", "filter_value": "Salary", "color": "#10a861" },
      { "id": "income_cat_interest", "name": "Interest", "kind": "income", "value": "500.0", "percentage": "10.0", "category_id": "cat_interest", "filter_value": "Interest", "color": "#6471eb" },
      { "id": "expense_cat_food", "name": "Food & Drink", "kind": "expense", "value": "400.0", "percentage": "26.7", "category_id": "cat_food", "filter_value": "Food & Drink", "color": "#e99537" },
      { "id": "expense_sub_cat_groceries", "name": "Groceries", "kind": "expense", "value": "300.0", "percentage": "75.0", "category_id": "cat_groceries", "filter_value": "Groceries", "color": "#e99537" },
      { "id": "expense_cat_rent", "name": "Rent", "kind": "expense", "value": "1000.0", "percentage": "66.7", "category_id": "cat_rent", "filter_value": "Rent", "color": "#4da568" },
      { "id": "expense_uncategorized", "name": "Uncategorized", "kind": "expense", "value": "100.0", "percentage": "6.7", "category_id": null, "filter_value": null, "color": null },
      { "id": "surplus_node", "name": "Surplus", "kind": "surplus", "value": "3500.0", "percentage": "70.0", "category_id": null, "filter_value": null, "color": null }
    ],
    "links": [
      { "source": 1, "target": 0, "value": "4500.0", "percentage": "90.0" },
      { "source": 2, "target": 0, "value": "500.0", "percentage": "10.0" },
      { "source": 0, "target": 3, "value": "400.0", "percentage": "26.7" },
      { "source": 3, "target": 4, "value": "300.0", "percentage": "75.0" },
      { "source": 0, "target": 5, "value": "1000.0", "percentage": "66.7" },
      { "source": 0, "target": 6, "value": "100.0", "percentage": "6.7" },
      { "source": 0, "target": 7, "value": "3500.0", "percentage": "70.0" }
    ]
  }
}
''';
