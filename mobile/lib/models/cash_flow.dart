/// Cash flow report models backed by `GET /api/v1/cash_flow?view=sankey`.
///
/// The server does all the aggregation (refund netting, parent/subcategory
/// partitioning, transfer exclusion); the client only reshapes the Sankey
/// graph into per-side category lists for the summary, chart and ranked list.
library;

/// Report periods offered by the mobile cash flow screen. They mirror the web
/// `Period` presets (`app/models/period.rb`) so the same label covers the same
/// date range on both clients.
enum CashFlowPeriod {
  currentMonth,
  lastMonth,
  last30Days,
  last90Days,
  currentYear,
  last365Days;

  /// Inclusive date range for this period relative to [today] (date part only).
  ///
  /// [monthStartDay] is the family's month start (`Family#month_start_day`,
  /// 1..28). Like the web's `Period.current_month_for` / `last_month_for`, it
  /// moves "This month" and "Last month" to the custom boundaries; the other
  /// presets are rolling or calendar-year ranges and ignore it.
  CashFlowDateRange rangeFor(DateTime today, {int monthStartDay = 1}) {
    final day = DateTime(today.year, today.month, today.day);
    switch (this) {
      case CashFlowPeriod.currentMonth:
        if (monthStartDay > 1) {
          // Family#current_custom_month_period: start to its end, which can
          // run past today (the web shows the whole custom month).
          final start = _customMonthStart(day, monthStartDay);
          return CashFlowDateRange(start, _customMonthEnd(start));
        }
        return CashFlowDateRange(DateTime(day.year, day.month, 1), day);
      case CashFlowPeriod.lastMonth:
        if (monthStartDay > 1) {
          final currentStart = _customMonthStart(day, monthStartDay);
          final previousDay = DateTime(
            currentStart.year,
            currentStart.month,
            currentStart.day - 1,
          );
          final start = _customMonthStart(previousDay, monthStartDay);
          return CashFlowDateRange(start, _customMonthEnd(start));
        }
        // Day 0 of the current month is the last day of the previous month.
        return CashFlowDateRange(
          DateTime(day.year, day.month - 1, 1),
          DateTime(day.year, day.month, 0),
        );
      case CashFlowPeriod.last30Days:
        return CashFlowDateRange(_daysBefore(day, 30), day);
      case CashFlowPeriod.last90Days:
        return CashFlowDateRange(_daysBefore(day, 90), day);
      case CashFlowPeriod.currentYear:
        return CashFlowDateRange(DateTime(day.year, 1, 1), day);
      case CashFlowPeriod.last365Days:
        return CashFlowDateRange(_daysBefore(day, 365), day);
    }
  }

  /// `Family#custom_month_start_for`.
  static DateTime _customMonthStart(DateTime day, int monthStartDay) =>
      day.day >= monthStartDay
          ? DateTime(day.year, day.month, monthStartDay)
          : DateTime(day.year, day.month - 1, monthStartDay);

  /// `Family#custom_month_end_for`: the day before the next month's start.
  static DateTime _customMonthEnd(DateTime start) =>
      DateTime(start.year, start.month + 1, start.day - 1);

  // Calendar arithmetic (not Duration) so DST transitions never shift the day.
  static DateTime _daysBefore(DateTime day, int days) =>
      DateTime(day.year, day.month, day.day - days);
}

/// Inclusive start/end dates of a report.
class CashFlowDateRange {
  const CashFlowDateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;

  String get startIso => isoDate(start);
  String get endIso => isoDate(end);

  /// `YYYY-MM-DD`, the format the Sure API expects for dates.
  static String isoDate(DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}';
  }

  @override
  bool operator ==(Object other) =>
      other is CashFlowDateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Which side of the cash flow a category belongs to.
enum CashFlowSide { income, expense }

/// One category on one side of the report (a root category; subcategories are
/// folded into [children]).
class CashFlowCategory {
  const CashFlowCategory({
    required this.id,
    required this.name,
    required this.side,
    required this.amount,
    required this.percentage,
    this.categoryId,
    this.color,
    this.children = const [],
    this.relatedSubcategoryIds = const [],
  });

  /// Stable node id from the API (e.g. `expense_<key>`).
  final String id;
  final String name;
  final CashFlowSide side;

  /// Nonnegative amount in the report currency.
  final double amount;

  /// Share of the side total, in percentage points (0–100), as computed by
  /// the server.
  final double percentage;

  /// Sure category id; `null` for synthetic buckets such as Uncategorized,
  /// which the transactions API cannot filter on.
  final String? categoryId;

  /// User category color (`#rrggbb`), when the category has one.
  final String? color;

  /// Subcategories with a nonzero amount on this side.
  final List<CashFlowCategory> children;

  /// Ids of this category's subcategories that the report lists on the other
  /// side only. The server partitions each category's net amount by
  /// direction, so a subcategory whose refunds outweigh its spending appears
  /// under the income counterpart of an expense category (and vice versa).
  final List<String> relatedSubcategoryIds;

  /// Category ids to request when drilling into this category's
  /// transactions: the category itself plus every subcategory the report
  /// knows on either side, like the web's category filter, which includes
  /// all subcategories of a parent.
  List<String> get transactionCategoryIds => {
        if (categoryId != null) categoryId!,
        for (final child in children)
          if (child.categoryId != null) child.categoryId!,
        ...relatedSubcategoryIds,
      }.toList(growable: false);

  CashFlowCategory _withRelatedSubcategoryIds(List<String> ids) =>
      CashFlowCategory(
        id: id,
        name: name,
        side: side,
        amount: amount,
        percentage: percentage,
        categoryId: categoryId,
        color: color,
        children: children,
        relatedSubcategoryIds: ids,
      );

  bool get canDrillDown => categoryId != null;
}

/// A cash flow report for one period.
class CashFlowReport {
  const CashFlowReport({
    required this.currency,
    required this.startDate,
    required this.endDate,
    required this.income,
    required this.spending,
    required this.netSavings,
    required this.incomeCategories,
    required this.expenseCategories,
  });

  final String currency;
  final DateTime startDate;
  final DateTime endDate;
  final double income;
  final double spending;
  final double netSavings;

  /// Income categories, largest first.
  final List<CashFlowCategory> incomeCategories;

  /// Expense categories, largest first.
  final List<CashFlowCategory> expenseCategories;

  /// Net savings as a percentage of income; `null` when income is not
  /// positive (matches the API's `savings_rate` semantics).
  double? get savingsRate => income > 0 ? netSavings / income * 100 : null;

  List<CashFlowCategory> categoriesFor(CashFlowSide side) =>
      side == CashFlowSide.income ? incomeCategories : expenseCategories;

  double totalFor(CashFlowSide side) =>
      side == CashFlowSide.income ? income : spending;

  bool get isEmpty => incomeCategories.isEmpty && expenseCategories.isEmpty;

  /// Parses the `view=sankey` envelope:
  /// `{currency, period: {start_date, end_date}, sankey: {income, spending,
  /// net_savings, nodes, links}}`.
  factory CashFlowReport.fromJson(Map<String, dynamic> json) {
    final period = _map(json['period']);
    final sankey = _map(json['sankey']);
    final nodes = (sankey['nodes'] as List? ?? const [])
        .map((n) => _map(n))
        .toList(growable: false);
    final links = (sankey['links'] as List? ?? const [])
        .map((l) => _map(l))
        .toList(growable: false);

    final centerIndexes = <int>{
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i]['kind'] == 'cash_flow' || nodes[i]['kind'] == 'account') i,
    };

    // Root categories are linked directly to a center node; subcategories
    // hang off a root (expense: root -> sub, income: sub -> root).
    final incomeRoots = <int>[];
    final expenseRoots = <int>[];
    final childrenOf = <int, List<int>>{};
    for (final link in links) {
      final source = _int(link['source']);
      final target = _int(link['target']);
      if (source == null || target == null) continue;
      if (source >= nodes.length || target >= nodes.length) continue;
      final sourceKind = nodes[source]['kind'];
      final targetKind = nodes[target]['kind'];

      if (centerIndexes.contains(target) && sourceKind == 'income') {
        if (!incomeRoots.contains(source)) incomeRoots.add(source);
      } else if (centerIndexes.contains(source) && targetKind == 'expense') {
        if (!expenseRoots.contains(target)) expenseRoots.add(target);
      } else if (sourceKind == 'expense' && targetKind == 'expense') {
        childrenOf.putIfAbsent(source, () => []).add(target);
      } else if (sourceKind == 'income' && targetKind == 'income') {
        childrenOf.putIfAbsent(target, () => []).add(source);
      }
    }

    CashFlowCategory build(int index, CashFlowSide side) {
      final node = nodes[index];
      final children = (childrenOf[index] ?? const <int>[])
          .map((c) => build(c, side))
          // The server only sends positive side amounts; anything else
          // could not be drawn in the chart, so it is not listed either.
          .where((c) => c.amount > 0)
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
      return CashFlowCategory(
        id: node['id']?.toString() ?? '$index',
        name: node['name']?.toString() ?? '',
        side: side,
        amount: _double(node['value']),
        percentage: _double(node['percentage']),
        categoryId: _nonEmpty(node['category_id']),
        color: _nonEmpty(node['color']),
        children: children,
      );
    }

    List<CashFlowCategory> side(List<int> roots, CashFlowSide s) =>
        roots.map((i) => build(i, s)).where((c) => c.amount > 0).toList()
          ..sort((a, b) => b.amount.compareTo(a.amount));

    final incomeCategories = side(incomeRoots, CashFlowSide.income);
    final expenseCategories = side(expenseRoots, CashFlowSide.expense);

    // Subcategory ids per root category id, across both sides.
    final subcategoryIds = <String, Set<String>>{};
    for (final root in [...incomeCategories, ...expenseCategories]) {
      final rootId = root.categoryId;
      if (rootId == null) continue;
      final ids = subcategoryIds.putIfAbsent(rootId, () => <String>{});
      for (final child in root.children) {
        if (child.categoryId != null) ids.add(child.categoryId!);
      }
    }
    List<CashFlowCategory> withRelated(List<CashFlowCategory> roots) => [
          for (final root in roots)
            if (root.categoryId == null)
              root
            else
              root._withRelatedSubcategoryIds(
                subcategoryIds[root.categoryId]!.difference({
                  for (final child in root.children) child.categoryId,
                }).toList(growable: false),
              ),
        ];

    return CashFlowReport(
      currency: json['currency']?.toString() ?? '',
      startDate: _date(period['start_date']),
      endDate: _date(period['end_date']),
      income: _double(sankey['income']),
      spending: _double(sankey['spending']),
      netSavings: _double(sankey['net_savings']),
      incomeCategories: withRelated(incomeCategories),
      expenseCategories: withRelated(expenseCategories),
    );
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static double _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return text == null || text.isEmpty ? null : text;
  }

  static DateTime _date(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '') ?? DateTime(1970);
}
