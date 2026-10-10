Map<String, dynamic> monthlySpendingFixture(
        {bool emptySelection = false, int missingRates = 0}) =>
    {
      'currency': 'USD',
      'basis': 'gross_expense',
      'as_of': '2025-01-10',
      'period': {
        'from': '2024-12-01',
        'to': '2025-01-01',
        'end_date': '2025-01-10'
      },
      'filters': {
        'account_ids': emptySelection ? <String>[] : ['a'],
        'category_ids': ['food']
      },
      'accounts': [
        {'id': 'a', 'name': 'Checking'}
      ],
      'categories': [
        {'id': 'food', 'name': 'Food', 'color': '#f97316'}
      ],
      'months': [
        {
          'month': '2024-12-01',
          'partial': false,
          'total': emptySelection ? '0.0' : '20.0',
          'missing_exchange_rates': 0,
          'categories': emptySelection
              ? []
              : [
                  {'id': 'food', 'amount': '20.0'}
                ]
        },
        {
          'month': '2025-01-01',
          'partial': true,
          'total': emptySelection ? '0.0' : '30.0',
          'missing_exchange_rates': missingRates,
          'categories': emptySelection
              ? []
              : [
                  {'id': 'food', 'amount': '30.0'}
                ]
        },
      ],
      'empty_selection': emptySelection,
      'missing_exchange_rates': missingRates,
    };
