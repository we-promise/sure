import 'package:flutter/foundation.dart';

import '../models/budget.dart';
import '../services/budgets_service.dart';
import '../services/log_service.dart';

/// Why a month could not be shown.
enum BudgetsLoadError { offline, unauthorized, failed }

/// State for the Budgets screen: the selected month, the budget(s) the server
/// has for it, and each category line with its actual spending.
///
/// The budgets API is read-only and its list endpoints leave out actual
/// amounts, so a month is assembled from the budget list (to find the month's
/// budget), the budget's show endpoint (totals) and one show request per
/// budget category (actual / remaining). Months already loaded in this session
/// are kept in memory, so flipping back is instant and still works offline.
class BudgetsProvider with ChangeNotifier {
  BudgetsProvider({
    BudgetsService? service,
    DateTime Function()? clock,
    bool Function()? isOffline,
  })  : _service = service ?? BudgetsService(),
        _clock = clock ?? DateTime.now,
        _isOffline = isOffline ?? (() => false) {
    _month = _firstOfMonth(_clock());
  }

  final BudgetsService _service;
  final DateTime Function() _clock;
  final bool Function() _isOffline;
  final LogService _log = LogService.instance;

  /// Concurrent per-category requests while assembling a month.
  static const int _categoryConcurrency = 6;
  static const int _perPage = 100;

  late DateTime _month;
  final Map<String, _MonthData> _cache = {};
  final Map<String, String> _selectedBudgetByMonth = {};
  bool _isLoading = false;
  BudgetsLoadError? _error;
  String? _errorMessage;
  bool _showingCachedWhileOffline = false;
  int _generation = 0;

  /// First day of the month being shown.
  DateTime get month => _month;
  bool get isLoading => _isLoading;
  BudgetsLoadError? get error => _error;
  String? get errorMessage => _errorMessage;

  /// True when the device is offline and the month shown came from memory.
  bool get showingCachedWhileOffline => _showingCachedWhileOffline;

  _MonthData? get _current => _cache[_monthKey(_month)];

  /// Whether the server returned a budget list for the month (possibly empty).
  bool get hasLoadedMonth => _current != null;

  /// All budgets visible to the user for this month: the household budget
  /// plus any personal or shared ones.
  List<Budget> get monthBudgets => _current?.budgets ?? const [];

  Budget? get budget => _current?.selected;

  List<BudgetCategory> get categories => _current?.categories ?? const [];

  /// Parent categories with their subcategories, limited to the lines the web
  /// budget page shows (budgeted, or with spending).
  List<BudgetCategoryGroup> get visibleGroups {
    final groups = BudgetCategoryGroup.build(categories);
    final visible = <BudgetCategoryGroup>[];
    for (final group in groups) {
      final children = group.children.where((c) => c.isVisible).toList();
      if (group.parent.isVisible || children.isNotEmpty) {
        visible.add(
          BudgetCategoryGroup(parent: group.parent, children: children),
        );
      }
    }
    return visible;
  }

  /// Number of visible category lines (parents and subcategories) that are
  /// over budget.
  int get overBudgetCount {
    var count = 0;
    for (final group in visibleGroups) {
      if (group.parent.isOverBudget) count++;
      count += group.children.where((c) => c.isOverBudget).length;
    }
    return count;
  }

  /// Budgets only exist for past and current months.
  bool get canGoNext => _month.isBefore(_firstOfMonth(_clock()));

  void previousMonth() => _setMonth(DateTime(_month.year, _month.month - 1));

  void nextMonth() {
    if (canGoNext) _setMonth(DateTime(_month.year, _month.month + 1));
  }

  void _setMonth(DateTime month) {
    _month = _firstOfMonth(month);
    _error = null;
    _errorMessage = null;
    _showingCachedWhileOffline = false;
    notifyListeners();
  }

  /// Switch between budgets when the month has more than one.
  Future<void> selectBudget({
    required String accessToken,
    required String budgetId,
  }) async {
    final key = _monthKey(_month);
    if (_cache[key]?.selected?.id == budgetId) return;
    _selectedBudgetByMonth[key] = budgetId;
    await loadMonth(accessToken: accessToken, forceRefresh: true);
  }

  /// Loads the selected month. Uses the in-memory copy unless [forceRefresh].
  Future<void> loadMonth({
    required String accessToken,
    bool forceRefresh = false,
  }) async {
    final key = _monthKey(_month);
    final month = _month;
    final generation = ++_generation;

    if (_isOffline()) {
      _showingCachedWhileOffline = _cache.containsKey(key);
      _error = _showingCachedWhileOffline ? null : BudgetsLoadError.offline;
      _errorMessage = null;
      _isLoading = false;
      notifyListeners();
      return;
    }

    if (!forceRefresh && _cache.containsKey(key)) {
      _showingCachedWhileOffline = false;
      _error = null;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _error = null;
    _errorMessage = null;
    _showingCachedWhileOffline = false;
    notifyListeners();

    try {
      final data = await _fetchMonth(accessToken, month);
      if (generation != _generation) return;
      _cache[key] = data;
      _log.info(
        'BudgetsProvider',
        'Loaded ${data.budgets.length} budget(s), '
            '${data.categories.length} categories for $key',
      );
    } on _BudgetsFetchException catch (e) {
      if (generation != _generation) return;
      _error = e.error;
      _errorMessage = e.message;
      _log.error('BudgetsProvider', 'Failed to load budgets for $key: $e');
    } catch (e) {
      if (generation != _generation) return;
      _error = BudgetsLoadError.failed;
      _errorMessage = null;
      _log.error('BudgetsProvider', 'Exception loading budgets for $key: $e');
    } finally {
      if (generation == _generation) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<_MonthData> _fetchMonth(String accessToken, DateTime month) async {
    // A family with a custom month start has budgets that begin mid-month and
    // end in the next one, so widen the window and match on the start month.
    final listResult = await _service.getBudgets(
      accessToken: accessToken,
      startDate: month,
      endDate: DateTime(month.year, month.month + 2, 0),
      perPage: _perPage,
    );
    _throwIfFailed(listResult);

    final budgets = (listResult['budgets'] as List<Budget>)
        .where(
          (b) =>
              b.startDate.year == month.year &&
              b.startDate.month == month.month,
        )
        .toList();

    if (budgets.isEmpty) {
      return _MonthData(budgets: budgets);
    }

    final key = _monthKey(month);
    final preferredId = _selectedBudgetByMonth[key];
    final summary = budgets.firstWhere(
      (b) => b.id == preferredId,
      orElse: () => budgets.first,
    );

    final results = await Future.wait([
      _service.getBudget(accessToken: accessToken, id: summary.id),
      _fetchAllCategories(accessToken, summary.id),
    ]);

    final budgetResult = results[0] as Map<String, dynamic>;
    _throwIfFailed(budgetResult);
    final detailed = budgetResult['budget'] as Budget;

    final indexCategories = results[1] as List<BudgetCategory>;
    final categories = await _withDerivedAmounts(accessToken, indexCategories);

    return _MonthData(
      budgets: budgets,
      selected: detailed,
      categories: categories,
    );
  }

  Future<List<BudgetCategory>> _fetchAllCategories(
    String accessToken,
    String budgetId,
  ) async {
    final all = <BudgetCategory>[];
    var page = 1;
    while (true) {
      final result = await _service.getBudgetCategories(
        accessToken: accessToken,
        budgetId: budgetId,
        page: page,
        perPage: _perPage,
      );
      _throwIfFailed(result);
      all.addAll(result['budget_categories'] as List<BudgetCategory>);

      final pagination = result['pagination'] as Map<String, dynamic>?;
      final totalPages = (pagination?['total_pages'] as num?)?.toInt() ?? 1;
      if (page >= totalPages || page >= 20) break;
      page++;
    }
    return all;
  }

  /// Replaces each index record with its show record (which carries actual
  /// spending). A line whose detail request fails keeps its budgeted amount,
  /// so one bad request never blanks the whole month; a 401 still fails it.
  Future<List<BudgetCategory>> _withDerivedAmounts(
    String accessToken,
    List<BudgetCategory> categories,
  ) async {
    final detailed = List<BudgetCategory>.of(categories);
    for (var i = 0; i < categories.length; i += _categoryConcurrency) {
      final end = (i + _categoryConcurrency).clamp(0, categories.length);
      final batch = await Future.wait([
        for (var j = i; j < end; j++)
          _service.getBudgetCategory(
            accessToken: accessToken,
            id: categories[j].id,
          ),
      ]);
      for (var k = 0; k < batch.length; k++) {
        final result = batch[k];
        if (result['success'] == true) {
          detailed[i + k] = result['budget_category'] as BudgetCategory;
        } else if (result['error'] == 'unauthorized') {
          _throwIfFailed(result);
        }
      }
    }
    return detailed;
  }

  void _throwIfFailed(Map<String, dynamic> result) {
    if (result['success'] == true) return;
    final error = result['error']?.toString();
    throw _BudgetsFetchException(
      error == 'unauthorized'
          ? BudgetsLoadError.unauthorized
          : BudgetsLoadError.failed,
      error == 'unauthorized' ? null : error,
    );
  }

  static DateTime _firstOfMonth(DateTime date) =>
      DateTime(date.year, date.month);

  static String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';
}

class _MonthData {
  const _MonthData({
    required this.budgets,
    this.selected,
    this.categories = const [],
  });

  final List<Budget> budgets;
  final Budget? selected;
  final List<BudgetCategory> categories;
}

class _BudgetsFetchException implements Exception {
  const _BudgetsFetchException(this.error, this.message);

  final BudgetsLoadError error;
  final String? message;

  @override
  String toString() => 'BudgetsFetchException($error, $message)';
}
