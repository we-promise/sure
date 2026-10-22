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

  /// First month of the budget period that contains today. For a family whose
  /// month starts on, say, the 15th, on October 10 that is September. Starts
  /// as the calendar month and is corrected by the first successful load.
  late DateTime _currentPeriodMonth = _firstOfMonth(_clock());
  bool _currentPeriodResolved = false;

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

  /// True while the selected budget is not initialized yet: the web page then
  /// shows every category rather than only the budgeted ones.
  bool get showsAllCategories => budget != null && !budget!.initialized;

  /// Parent categories with their subcategories, limited to the lines the web
  /// budget page shows (budgeted, or with spending).
  List<BudgetCategoryGroup> get visibleGroups {
    final groups = BudgetCategoryGroup.build(categories);
    // Web: `budget.initialized? ? visible_on_track? : true`. A budget that
    // hasn't been set up yet lists every category so it can be configured.
    if (showsAllCategories) return groups;
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

  /// The server accepts budgets up to two years past the current period
  /// (web: `Budget.latest_valid_budget_start_date`), so planned future months
  /// stay reachable.
  bool get canGoNext => _month.isBefore(
        DateTime(_currentPeriodMonth.year + 2, _currentPeriodMonth.month),
      );

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
    // The month's budget list is already known; only the chosen budget's
    // detail and categories need fetching.
    await _loadMonth(
      accessToken: accessToken,
      forceRefresh: true,
      knownBudgets: _cache[key]?.budgets,
    );
  }

  /// Shows the session-expired state, e.g. when no access token is available.
  void markUnauthorized() {
    _generation++;
    _isLoading = false;
    _error = BudgetsLoadError.unauthorized;
    _errorMessage = null;
    _showingCachedWhileOffline = false;
    notifyListeners();
  }

  /// Loads the selected month. Uses the in-memory copy unless [forceRefresh].
  Future<void> loadMonth({
    required String accessToken,
    bool forceRefresh = false,
  }) =>
      _loadMonth(accessToken: accessToken, forceRefresh: forceRefresh);

  Future<void> _loadMonth({
    required String accessToken,
    bool forceRefresh = false,
    List<Budget>? knownBudgets,
  }) async {
    if (!_currentPeriodResolved && !_isOffline()) {
      // Show the spinner while the current period resolves; every branch
      // below resets the flag or re-sets it for the month fetch.
      _isLoading = true;
      _error = null;
      _errorMessage = null;
      notifyListeners();
      await _resolveCurrentPeriod(accessToken);
    }
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
      // A superseded request for another month can't clear this any more.
      _isLoading = false;
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
      final data = await _fetchMonth(
        accessToken,
        month,
        knownBudgets: knownBudgets,
      );
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

  /// Finds the budget whose period contains today and, if the user hasn't
  /// navigated yet, opens on it. Without one (no budget yet, or a failed
  /// request) the calendar month stays, as before.
  Future<void> _resolveCurrentPeriod(String accessToken) async {
    final today = _clock();
    final day = DateTime(today.year, today.month, today.day);
    final initialMonth = _firstOfMonth(today);
    try {
      final result = await _service.getBudgets(
        accessToken: accessToken,
        startDate: DateTime(initialMonth.year, initialMonth.month - 1),
        endDate: DateTime(initialMonth.year, initialMonth.month + 2, 0),
        perPage: _perPage,
      );
      if (result['success'] != true) return;
      _currentPeriodResolved = true;
      for (final b in result['budgets'] as List<Budget>) {
        if (!b.startDate.isAfter(day) && !b.endDate.isBefore(day)) {
          _currentPeriodMonth = _firstOfMonth(b.startDate);
          if (_month == initialMonth) _month = _currentPeriodMonth;
          break;
        }
      }
    } catch (e) {
      _log.error('BudgetsProvider', 'Could not resolve current period: $e');
    }
  }

  Future<_MonthData> _fetchMonth(
    String accessToken,
    DateTime month, {
    List<Budget>? knownBudgets,
  }) async {
    if (knownBudgets != null) {
      return _fetchSelected(accessToken, month, knownBudgets);
    }
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

    return _fetchSelected(accessToken, month, budgets);
  }

  Future<_MonthData> _fetchSelected(
    String accessToken,
    DateTime month,
    List<Budget> budgets,
  ) async {
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
  /// spending). A line whose detail record is gone (404) keeps its budgeted
  /// amount; any other failure (401, network, server error) fails the month,
  /// so a partial month is never cached as complete.
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
        } else if (result['error'] != 'not_found') {
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
