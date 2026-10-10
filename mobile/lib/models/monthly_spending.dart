class SpendingOption {
  const SpendingOption({required this.id, required this.name, this.color});
  final String id;
  final String name;
  final String? color;

  factory SpendingOption.fromJson(Map<String, dynamic> json) => SpendingOption(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String?,
      );
}

class SpendingMonth {
  SpendingMonth({
    required this.month,
    required this.total,
    required this.partial,
    required this.missingExchangeRates,
    required this.amounts,
  });
  final String month;
  // Decimal strings from the server become doubles only for presentation.
  final double total;
  final bool partial;
  final int missingExchangeRates;
  final Map<String, double> amounts;

  factory SpendingMonth.fromJson(Map<String, dynamic> json) => SpendingMonth(
        month: json['month'] as String,
        total: double.parse(json['total'] as String),
        partial: json['partial'] as bool,
        missingExchangeRates: json['missing_exchange_rates'] as int,
        amounts: {
          for (final category in json['categories'] as List)
            category['id'] as String:
                double.parse(category['amount'] as String),
        },
      );
}

class MonthlySpendingSelection {
  const MonthlySpendingSelection(
      {this.from, this.to, this.accountIds, this.categoryIds, this.period});
  final String? period;
  final String? from;
  final String? to;
  final List<String>? accountIds;
  final List<String>? categoryIds;

  MonthlySpendingSelection resolved(DateTime now) {
    String date(DateTime value) => value.toIso8601String().substring(0, 10);
    String? start = from;
    String? end = to;
    if (period == 'last_twelve') {
      // Let the server choose its current month and reporting time zone.
      start = null;
      end = null;
    } else if (period == 'this_year') {
      start = date(DateTime(now.year));
      end = date(DateTime(now.year, now.month));
    } else if (period == 'previous_year') {
      start = date(DateTime(now.year - 1));
      end = date(DateTime(now.year - 1, 12));
    }
    return MonthlySpendingSelection(
        from: start,
        to: end,
        accountIds: accountIds,
        categoryIds: categoryIds,
        period: period);
  }

  Map<String, dynamic> get query => {
        if (from != null) 'from': from!,
        if (to != null) 'to': to!,
        // Empty arrays must be transmitted explicitly, rather than omitted.
        if (accountIds != null)
          'account_ids[]': accountIds!.isEmpty ? [''] : accountIds!,
        if (categoryIds != null)
          'category_ids[]': categoryIds!.isEmpty ? [''] : categoryIds!,
      };
}

class MonthlySpendingData {
  MonthlySpendingData.fromJson(Map<String, dynamic> json)
      : currency = json['currency'] as String,
        asOf = DateTime.parse(json['as_of'] as String),
        from = json['period']['from'] as String,
        to = json['period']['to'] as String,
        accountIds = List<String>.from(json['filters']['account_ids']),
        categoryIds = List<String>.from(json['filters']['category_ids']),
        accounts = (json['accounts'] as List)
            .map((item) => SpendingOption.fromJson(item))
            .toList(),
        categories = (json['categories'] as List)
            .map((item) => SpendingOption.fromJson(item))
            .toList(),
        months = (json['months'] as List)
            .map((item) => SpendingMonth.fromJson(item))
            .toList(),
        emptySelection = json['empty_selection'] as bool,
        missingExchangeRates = json['missing_exchange_rates'] as int;

  final String currency;
  final DateTime asOf;
  final String from;
  final String to;
  final List<String> accountIds;
  final List<String> categoryIds;
  final List<SpendingOption> accounts;
  final List<SpendingOption> categories;
  final List<SpendingMonth> months;
  final bool emptySelection;
  final int missingExchangeRates;
}
