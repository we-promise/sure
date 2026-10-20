/// A monthly budget as returned by `GET /api/v1/budgets` and
/// `GET /api/v1/budgets/:id`.
///
/// Money fields come in pairs: a server-formatted string (already localized
/// with the budget currency, e.g. `$1,234.56`) and the same value in minor
/// units (`*_cents`). The strings are what we render, so formatting stays in
/// lockstep with the web app; the cents drive comparisons and progress bars.
///
/// The index endpoint omits the derived amounts (actual spending, available to
/// spend, ...), so those are nullable and only populated from the show
/// endpoint.
class Budget {
  const Budget({
    required this.id,
    required this.startDate,
    required this.endDate,
    required this.name,
    required this.currency,
    required this.initialized,
    required this.current,
    this.budgetedSpending,
    this.budgetedSpendingCents,
    this.expectedIncome,
    this.expectedIncomeCents,
    this.allocatedSpending,
    this.allocatedSpendingCents,
    this.actualSpending,
    this.actualSpendingCents,
    this.actualIncome,
    this.actualIncomeCents,
    this.availableToSpend,
    this.availableToSpendCents,
    this.availableToAllocate,
    this.availableToAllocateCents,
  });

  final String id;
  final DateTime startDate;
  final DateTime endDate;
  final String name;
  final String currency;
  final bool initialized;
  final bool current;

  final String? budgetedSpending;
  final int? budgetedSpendingCents;
  final String? expectedIncome;
  final int? expectedIncomeCents;
  final String? allocatedSpending;
  final int? allocatedSpendingCents;

  final String? actualSpending;
  final int? actualSpendingCents;
  final String? actualIncome;
  final int? actualIncomeCents;
  final String? availableToSpend;
  final int? availableToSpendCents;
  final String? availableToAllocate;
  final int? availableToAllocateCents;

  /// Whether this record carries the derived amounts (show endpoint).
  bool get hasDerivedAmounts => actualSpendingCents != null;

  bool get isOverBudget => (availableToSpendCents ?? 0) < 0;

  /// Share of the spendable amount already spent, 0..∞ (1.0 == 100%).
  ///
  /// `available_to_spend` is the budget (plus any rollover) minus actual
  /// spending, so `actual + available` reconstructs what there was to spend.
  double get spentFraction {
    final actual = actualSpendingCents ?? 0;
    final available = availableToSpendCents ?? 0;
    return spentFractionFor(actual: actual, total: actual + available);
  }

  factory Budget.fromJson(Map<String, dynamic> json) {
    return Budget(
      id: json['id']?.toString() ?? '',
      startDate: _parseDate(json['start_date']),
      endDate: _parseDate(json['end_date']),
      name: json['name']?.toString() ?? '',
      currency: json['currency']?.toString() ?? '',
      initialized: json['initialized'] == true,
      current: json['current'] == true,
      budgetedSpending: _string(json['budgeted_spending']),
      budgetedSpendingCents: _int(json['budgeted_spending_cents']),
      expectedIncome: _string(json['expected_income']),
      expectedIncomeCents: _int(json['expected_income_cents']),
      allocatedSpending: _string(json['allocated_spending']),
      allocatedSpendingCents: _int(json['allocated_spending_cents']),
      actualSpending: _string(json['actual_spending']),
      actualSpendingCents: _int(json['actual_spending_cents']),
      actualIncome: _string(json['actual_income']),
      actualIncomeCents: _int(json['actual_income_cents']),
      availableToSpend: _string(json['available_to_spend']),
      availableToSpendCents: _int(json['available_to_spend_cents']),
      availableToAllocate: _string(json['available_to_allocate']),
      availableToAllocateCents: _int(json['available_to_allocate_cents']),
    );
  }
}

/// The category a [BudgetCategory] belongs to, as embedded in the API payload.
class BudgetCategoryInfo {
  const BudgetCategoryInfo({
    required this.id,
    required this.name,
    this.color,
    this.lucideIcon,
    this.parentId,
  });

  final String id;
  final String name;
  final String? color;
  final String? lucideIcon;
  final String? parentId;

  factory BudgetCategoryInfo.fromJson(Map<String, dynamic> json) {
    final parentId = json['parent_id']?.toString();
    return BudgetCategoryInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      color: _string(json['color']),
      lucideIcon: _string(json['lucide_icon']),
      parentId: (parentId == null || parentId.isEmpty) ? null : parentId,
    );
  }
}

/// One category line of a budget, from `GET /api/v1/budget_categories[/:id]`.
///
/// Mirrors the classification helpers on the Rails `BudgetCategory` model
/// (`budgeted?`, `over_budget?`, `near_limit?`, `visible_on_track?`) using only
/// the fields the API exposes.
class BudgetCategory {
  const BudgetCategory({
    required this.id,
    required this.budgetId,
    required this.currency,
    required this.subcategory,
    required this.inheritsParentBudget,
    required this.rolloverEnabled,
    required this.category,
    this.budgetedSpending,
    this.budgetedSpendingCents,
    this.displayBudgetedSpending,
    this.displayBudgetedSpendingCents,
    this.actualSpending,
    this.actualSpendingCents,
    this.rolledOverAmount,
    this.rolledOverAmountCents,
    this.availableToSpend,
    this.availableToSpendCents,
    this.sharedBudgetCents,
  });

  final String id;
  final String budgetId;
  final String currency;
  final bool subcategory;
  final bool inheritsParentBudget;
  final bool rolloverEnabled;
  final BudgetCategoryInfo category;

  final String? budgetedSpending;
  final int? budgetedSpendingCents;
  final String? displayBudgetedSpending;
  final int? displayBudgetedSpendingCents;

  final String? actualSpending;
  final int? actualSpendingCents;
  final String? rolledOverAmount;
  final int? rolledOverAmountCents;
  final String? availableToSpend;
  final int? availableToSpendCents;

  /// For a subcategory sharing its parent's budget: the part of the parent's
  /// budget (plus rollover) not reserved by sibling subcategories with their
  /// own allocation. Set by [BudgetCategoryGroup.build].
  final int? sharedBudgetCents;

  /// A copy carrying [sharedBudgetCents].
  BudgetCategory withSharedBudgetCents(int cents) => BudgetCategory(
        id: id,
        budgetId: budgetId,
        currency: currency,
        subcategory: subcategory,
        inheritsParentBudget: inheritsParentBudget,
        rolloverEnabled: rolloverEnabled,
        category: category,
        budgetedSpending: budgetedSpending,
        budgetedSpendingCents: budgetedSpendingCents,
        displayBudgetedSpending: displayBudgetedSpending,
        displayBudgetedSpendingCents: displayBudgetedSpendingCents,
        actualSpending: actualSpending,
        actualSpendingCents: actualSpendingCents,
        rolledOverAmount: rolledOverAmount,
        rolledOverAmountCents: rolledOverAmountCents,
        availableToSpend: availableToSpend,
        availableToSpendCents: availableToSpendCents,
        sharedBudgetCents: cents,
      );

  String get name => category.name;
  String? get parentCategoryId => category.parentId;

  /// Whether this record carries the derived amounts (show endpoint).
  bool get hasDerivedAmounts => actualSpendingCents != null;

  int get _actual => actualSpendingCents ?? 0;
  int get _available => availableToSpendCents ?? 0;

  /// The month's allocation plus any carried-over amount — "is there money in
  /// this envelope" (web: `budgeted?`).
  int get effectiveBudgetCents =>
      (displayBudgetedSpendingCents ?? 0) + (rolledOverAmountCents ?? 0);

  bool get isBudgeted => effectiveBudgetCents > 0;

  /// Over budget: either spending against no budget at all, or a negative
  /// amount left (web: `any_over_budget?`). Subcategories that share their
  /// parent's budget never go negative on their own; the parent does.
  bool get isOverBudget {
    if (!isBudgeted) return _actual > 0;
    return _available < 0;
  }

  /// Share spent, 0..∞ (1.0 == 100%).
  double get spentFraction {
    if (inheritsParentBudget) {
      // The API clamps a shared child's available amount at zero, so measure
      // its spending against the shared pool it draws from: the parent's
      // budget less ring-fenced siblings (web: `percent_of_budget_spent`).
      return spentFractionFor(
        actual: _actual,
        total: sharedBudgetCents ?? effectiveBudgetCents,
      );
    }
    // For everything else `available = budget + rollover - actual`.
    return spentFractionFor(actual: _actual, total: _actual + _available);
  }

  /// Within 10% of the limit but not over it (web: `near_limit?`).
  bool get isNearLimit => !isOverBudget && spentFraction >= 0.9;

  /// Whether the web budget page would show this line at all: budgeted lines
  /// (shared subcategories only once they have spending) and anything with
  /// spending.
  bool get isVisible {
    if (_actual > 0) return true;
    if (!isBudgeted) return false;
    return !inheritsParentBudget;
  }

  factory BudgetCategory.fromJson(Map<String, dynamic> json) {
    final categoryJson = json['category'];
    return BudgetCategory(
      id: json['id']?.toString() ?? '',
      budgetId: json['budget_id']?.toString() ?? '',
      currency: json['currency']?.toString() ?? '',
      subcategory: json['subcategory'] == true,
      inheritsParentBudget: json['inherits_parent_budget'] == true,
      rolloverEnabled: json['rollover_enabled'] == true,
      category: categoryJson is Map
          ? BudgetCategoryInfo.fromJson(categoryJson.cast<String, dynamic>())
          : const BudgetCategoryInfo(id: '', name: ''),
      budgetedSpending: _string(json['budgeted_spending']),
      budgetedSpendingCents: _int(json['budgeted_spending_cents']),
      displayBudgetedSpending: _string(json['display_budgeted_spending']),
      displayBudgetedSpendingCents: _int(
        json['display_budgeted_spending_cents'],
      ),
      actualSpending: _string(json['actual_spending']),
      actualSpendingCents: _int(json['actual_spending_cents']),
      rolledOverAmount: _string(json['rolled_over_amount']),
      rolledOverAmountCents: _int(json['rolled_over_amount_cents']),
      availableToSpend: _string(json['available_to_spend']),
      availableToSpendCents: _int(json['available_to_spend_cents']),
    );
  }
}

/// A parent budget category with its subcategories, in display order.
class BudgetCategoryGroup {
  const BudgetCategoryGroup({required this.parent, required this.children});

  final BudgetCategory parent;
  final List<BudgetCategory> children;

  /// Every category id whose transactions roll up into [parent]'s actual
  /// spending (the parent and all of its subcategories).
  List<String> get categoryIds => [
        parent.category.id,
        ...children.map((c) => c.category.id),
      ];

  bool get hasOverBudget =>
      parent.isOverBudget || children.any((c) => c.isOverBudget);

  /// Groups [categories] by parent, keeping the server order (name ASC) and
  /// placing subcategories whose parent is not in the list as their own group.
  static List<BudgetCategoryGroup> build(List<BudgetCategory> categories) {
    final byCategoryId = {for (final c in categories) c.category.id: c};
    final childrenByParent = <String, List<BudgetCategory>>{};
    final roots = <BudgetCategory>[];

    for (final c in categories) {
      final parentId = c.parentCategoryId;
      if (parentId != null && byCategoryId.containsKey(parentId)) {
        childrenByParent.putIfAbsent(parentId, () => []).add(c);
      } else {
        roots.add(c);
      }
    }

    return [
      for (final root in roots)
        BudgetCategoryGroup(
          parent: root,
          children: _withSharedBudgets(
            root,
            childrenByParent[root.category.id] ?? const [],
          ),
        ),
    ];
  }

  static List<BudgetCategory> _withSharedBudgets(
    BudgetCategory parent,
    List<BudgetCategory> children,
  ) {
    if (!children.any((c) => c.inheritsParentBudget)) return children;
    final ringFenced = children
        .where((c) => !c.inheritsParentBudget)
        .fold<int>(0, (sum, c) => sum + (c.budgetedSpendingCents ?? 0));
    // The API's parent rollover is Rails' display_rolled_over_amount: the
    // parent's own plus its ring-fenced children's. The shared pool only
    // gets the parent's own, so take the ring-fenced rollovers back out.
    final ringFencedRollover = children
        .where((c) => !c.inheritsParentBudget)
        .fold<int>(0, (sum, c) => sum + (c.rolledOverAmountCents ?? 0));
    final pool = (parent.budgetedSpendingCents ?? 0) +
        ((parent.rolledOverAmountCents ?? 0) - ringFencedRollover) -
        ringFenced;
    final shared = pool < 0 ? 0 : pool;
    return [
      for (final c in children)
        c.inheritsParentBudget ? c.withSharedBudgetCents(shared) : c,
    ];
  }
}

/// Fraction spent of [total], with the web app's zero-budget rules: nothing
/// budgeted and nothing spent is 0%, spending against nothing is 100%.
double spentFractionFor({required int actual, required int total}) {
  if (total <= 0) return actual > 0 ? 1.0 : 0.0;
  if (actual <= 0) return 0.0;
  return actual / total;
}

DateTime _parseDate(dynamic value) {
  return DateTime.tryParse(value?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

String? _string(dynamic value) {
  if (value == null) return null;
  final s = value.toString();
  return s.isEmpty ? null : s;
}

int? _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}
