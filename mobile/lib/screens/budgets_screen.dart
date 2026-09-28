import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/budget.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/budgets_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../utils/money_masker.dart';
import '../widgets/money_text.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_card.dart';

Future<String> _token(BuildContext context) async {
  final token = await context.read<AuthProvider>().getValidAccessToken();
  if (token == null) throw BudgetLoadError.unauthorized;
  return token;
}

String _period(BuildContext context, Budget budget) {
  final format = DateFormat.yMMMd(Localizations.localeOf(context).toString());
  return '${format.format(budget.startDate)} – ${format.format(budget.endDate)}';
}

class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key, this.service});

  final BudgetsService? service;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  late final BudgetsService _service = widget.service ?? BudgetsService();
  late Future<BudgetPage<Budget>> _future;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<BudgetPage<Budget>> _load() async =>
      _service.getBudgets(accessToken: await _token(context), page: _page);

  Future<void> _refresh([int? page]) async {
    setState(() {
      _page = page ?? _page;
      _future = _load();
    });
    try {
      await _future;
    } catch (_) {
      // The FutureBuilder renders the localized error and retry action.
    }
  }

  @override
  void dispose() {
    if (widget.service == null) _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.budgetsTitle)),
      body: SafeArea(
        child: FutureBuilder<BudgetPage<Budget>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _BudgetError(error: snapshot.error, retry: _refresh);
            }
            final result = snapshot.data!;
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(SureSpacing.xl),
                children: [
                  Text(l.budgetsReadOnly),
                  const SizedBox(height: SureSpacing.xl),
                  if (result.items.isEmpty) Text(l.budgetsEmpty),
                  for (final budget in result.items)
                    SureCard(
                      margin: const EdgeInsets.only(bottom: SureSpacing.lg),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => _BudgetDetailScreen(
                              budget: budget,
                              service: _service,
                            ),
                          )),
                      child: Semantics(
                        button: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(budget.name,
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(_period(context, budget)),
                            Text(budget.currency),
                            _AmountRow(
                                label: l.budgetsPlanned,
                                value: budget.amounts.budgeted),
                          ],
                        ),
                      ),
                    ),
                  _PageControls(
                      page: result.page,
                      totalPages: result.totalPages,
                      onPage: _refresh),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BudgetDetailScreen extends StatefulWidget {
  const _BudgetDetailScreen({required this.budget, required this.service});
  final Budget budget;
  final BudgetsService service;

  @override
  State<_BudgetDetailScreen> createState() => _BudgetDetailScreenState();
}

class _BudgetDetailScreenState extends State<_BudgetDetailScreen> {
  late Future<(Budget, BudgetPage<BudgetCategory>)> _future;
  int _page = 1;
  int _generation = 0;
  final _categoryStates = <String, _CategoryState>{};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(Budget, BudgetPage<BudgetCategory>)> _load() async {
    final page = _page;
    final token = await _token(context);
    final results = await Future.wait<Object>([
      widget.service.getBudget(accessToken: token, id: widget.budget.id),
      widget.service.getCategories(
        accessToken: token,
        budgetId: widget.budget.id,
        page: page,
      ),
    ]);
    return (results[0] as Budget, results[1] as BudgetPage<BudgetCategory>);
  }

  Future<void> _refresh([int? page]) async {
    setState(() {
      _page = page ?? _page;
      if (page == null) {
        _generation++;
        _categoryStates.clear();
      }
      _future = _load();
    });
    try {
      await _future;
    } catch (_) {
      // Keep failure handling in the FutureBuilder.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.budget.name)),
      body: SafeArea(
        child: FutureBuilder<(Budget, BudgetPage<BudgetCategory>)>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _BudgetError(error: snapshot.error, retry: _refresh);
            }
            final (budget, categories) = snapshot.data!;
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(SureSpacing.xl),
                children: [
                  Text('${_period(context, budget)} · ${budget.currency}'),
                  const SizedBox(height: SureSpacing.xl),
                  if (!budget.initialized) Text(l.budgetsNotInitialized),
                  SureCard(child: _Amounts(amounts: budget.amounts)),
                  const SizedBox(height: SureSpacing.xxl),
                  Text(l.budgetsCategories,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(l.budgetsCategoryHint),
                  const SizedBox(height: SureSpacing.lg),
                  if (categories.items.isEmpty) Text(l.budgetsNoCategories),
                  for (final category in categories.items)
                    _CategoryTile(
                      key: ValueKey('${category.id}:$_generation'),
                      category: category,
                      service: widget.service,
                      state: _categoryStates.putIfAbsent(
                          category.id, () => _CategoryState()),
                    ),
                  _PageControls(
                      page: categories.page,
                      totalPages: categories.totalPages,
                      onPage: _refresh),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// Owned by the detail screen so removing a page's widgets does not lose state.
class _CategoryState {
  bool expanded = false;
  Future<BudgetCategory>? future;
}

class _CategoryTile extends StatefulWidget {
  const _CategoryTile(
      {super.key,
      required this.category,
      required this.service,
      required this.state});
  final BudgetCategory category;
  final BudgetsService service;
  final _CategoryState state;

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  Future<BudgetCategory> _load() async => widget.service.getCategory(
        accessToken: await _token(context),
        id: widget.category.id,
      );

  void _refresh() {
    setState(() {
      widget.state.future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ExpansionTile(
      initiallyExpanded: widget.state.expanded,
      title: Text(widget.category.name),
      subtitle: _AmountRow(
          label: l.budgetsPlanned, value: widget.category.amounts.budgeted),
      onExpansionChanged: (expanded) {
        widget.state.expanded = expanded;
        if (expanded && widget.state.future == null) _refresh();
      },
      children: [
        if (widget.state.future != null)
          Padding(
            padding: const EdgeInsets.all(SureSpacing.xl),
            child: FutureBuilder<BudgetCategory>(
              future: widget.state.future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const CircularProgressIndicator();
                }
                if (snapshot.hasError) {
                  return _BudgetError(error: snapshot.error, retry: _refresh);
                }
                final category = snapshot.data!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (category.inheritsParentBudget)
                      Text(l.budgetsSharedLimit),
                    _Amounts(
                        amounts: category.amounts,
                        showProgress: !category.inheritsParentBudget),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Amounts extends StatelessWidget {
  const _Amounts({required this.amounts, this.showProgress = true});
  final BudgetAmounts amounts;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hidden = context.watch<PrivacyProvider>().hidden;
    final palette = SureColors.of(context).palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AmountRow(label: l.budgetsPlanned, value: amounts.budgeted),
        _AmountRow(label: l.budgetsSpent, value: amounts.spent),
        if (amounts.rollover != null)
          _AmountRow(label: l.budgetsRollover, value: amounts.rollover),
        _AmountRow(
            label: l.budgetsRemaining,
            value: amounts.remaining,
            overBudget: amounts.overBudget && !hidden),
        if (!hidden && amounts.overBudget)
          Text(l.budgetsOverBudget,
              style: TextStyle(color: palette.destructive)),
        // Hiding amounts also hides the ratio and overspending status.
        if (!hidden && showProgress && amounts.progress != null) ...[
          const SizedBox(height: SureSpacing.lg),
          LinearProgressIndicator(
            value: amounts.progress,
            color: amounts.overBudget ? palette.destructive : palette.success,
            backgroundColor: palette.surfaceInset,
            semanticsLabel: l.budgetsProgress,
            semanticsValue: NumberFormat.percentPattern(
                    Localizations.localeOf(context).toString())
                .format(amounts.progress),
          ),
        ],
      ],
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow(
      {required this.label, required this.value, this.overBudget = false});
  final String label;
  final String? value;
  final bool overBudget;

  @override
  Widget build(BuildContext context) {
    final hidden = context.watch<PrivacyProvider>().hidden;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SureSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: SureSpacing.md),
          Flexible(
            child: Text(MoneyMasker.mask(value ?? '—', hidden: hidden),
                textAlign: TextAlign.end,
                style: SureMoney.tabular(Theme.of(context).textTheme.bodyMedium)
                    .copyWith(
                  fontWeight: FontWeight.w600,
                  color: overBudget
                      ? SureColors.of(context).palette.destructive
                      : null,
                )),
          ),
        ],
      ),
    );
  }
}

class _PageControls extends StatelessWidget {
  const _PageControls(
      {required this.page, required this.totalPages, required this.onPage});
  final int page;
  final int totalPages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SureSpacing.xl),
      child:
          Wrap(spacing: SureSpacing.md, runSpacing: SureSpacing.md, children: [
        SureButton(
            label: l.budgetsPrevious,
            variant: SureButtonVariant.secondary,
            onPressed: page > 1 ? () => onPage(page - 1) : null),
        Text(l.budgetsPage(page, totalPages)),
        SureButton(
            label: l.budgetsNext,
            variant: SureButtonVariant.secondary,
            onPressed: page < totalPages ? () => onPage(page + 1) : null),
      ]),
    );
  }
}

class _BudgetError extends StatelessWidget {
  const _BudgetError({required this.error, required this.retry});
  final Object? error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final message = switch (error) {
      BudgetLoadError.unauthorized => l.budgetsSessionExpired,
      BudgetLoadError.forbidden => l.budgetsForbidden,
      BudgetLoadError.notFound => l.budgetsNotFound,
      _ => l.budgetsUnavailable,
    };
    return Padding(
      padding: const EdgeInsets.all(SureSpacing.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message),
        const SizedBox(height: SureSpacing.lg),
        SureButton(label: l.commonTryAgain, onPressed: retry),
      ]),
    );
  }
}
