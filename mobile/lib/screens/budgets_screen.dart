import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/budget.dart';
import '../providers/auth_provider.dart';
import '../providers/budgets_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/connectivity_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../widgets/budget_category_row.dart';
import '../widgets/budget_summary_card.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_card.dart';
import '../widgets/sure_chip.dart';
import '../widgets/sure_segmented_control.dart';
import 'budget_category_transactions_screen.dart';

/// Monthly budget overview, matching the web Budgets page: month navigation,
/// budgeted / actual / remaining totals and a progress bar per category, with
/// subcategories nested under their parent. Tapping a category opens its
/// transactions for that budget period. Read-only: budgets are edited on web.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key, this.provider, this.accessTokenLoader});

  /// Injected for tests; otherwise the screen owns its provider.
  final BudgetsProvider? provider;

  /// Injected for tests; defaults to [AuthProvider.getValidAccessToken].
  final Future<String?> Function()? accessTokenLoader;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

enum _CategoryFilter { all, overBudget }

class _BudgetsScreenState extends State<BudgetsScreen> {
  late final BudgetsProvider _provider;
  late final bool _ownsProvider;
  _CategoryFilter _filter = _CategoryFilter.all;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget.provider == null;
    _provider = widget.provider ??
        BudgetsProvider(
          isOffline: () {
            if (!mounted) return false;
            try {
              return context.read<ConnectivityService>().isOffline;
            } on ProviderNotFoundException {
              return false;
            }
          },
        );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    if (_ownsProvider) _provider.dispose();
    super.dispose();
  }

  Future<String?> _accessToken() {
    final loader = widget.accessTokenLoader;
    if (loader != null) return loader();
    return context.read<AuthProvider>().getValidAccessToken();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final token = await _accessToken();
    if (!mounted || token == null) return;
    await _provider.loadMonth(accessToken: token, forceRefresh: forceRefresh);
  }

  void _changeMonth(VoidCallback change) {
    change();
    setState(() => _filter = _CategoryFilter.all);
    _load();
  }

  Future<void> _selectBudget(String budgetId) async {
    final token = await _accessToken();
    if (!mounted || token == null) return;
    setState(() => _filter = _CategoryFilter.all);
    await _provider.selectBudget(accessToken: token, budgetId: budgetId);
  }

  void _openCategory(Budget budget, BudgetCategory bc, List<String> ids) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BudgetCategoryTransactionsScreen(
          title: bc.name,
          periodLabel: _periodLabel(context, budget.startDate, budget),
          categoryIds: ids,
          startDate: budget.startDate,
          endDate: budget.endDate,
          accessTokenLoader: widget.accessTokenLoader,
        ),
      ),
    );
  }

  static String _periodLabel(BuildContext context, DateTime month, Budget? b) {
    // The server name covers families with a custom month start
    // ("Oct 15 - Nov 14, 2026"); otherwise format the month locally.
    if (b != null && b.name.isNotEmpty) return b.name;
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMM(locale).format(month);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<BudgetsProvider>.value(
      value: _provider,
      child: Consumer<BudgetsProvider>(
        builder: (context, provider, _) => _buildScaffold(context, provider),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, BudgetsProvider provider) {
    final l = AppLocalizations.of(context);
    final hideAmounts = context.watch<PrivacyProvider>().hidden;

    return Scaffold(
      appBar: AppBar(title: Text(l.budgetsTitle)),
      body: RefreshIndicator(
        onRefresh: () => _load(forceRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            SureSpacing.xl,
            SureSpacing.md,
            SureSpacing.xl,
            SureSpacing.huge,
          ),
          children: [
            _buildMonthHeader(context, provider),
            ..._buildBody(context, provider, hideAmounts),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthHeader(BuildContext context, BudgetsProvider provider) {
    final l = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: l.budgetsPreviousMonth,
          onPressed: () => _changeMonth(provider.previousMonth),
        ),
        Expanded(
          child: Text(
            _periodLabel(context, provider.month, provider.budget),
            textAlign: TextAlign.center,
            style: textTheme.titleMedium,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: l.budgetsNextMonth,
          onPressed: provider.canGoNext
              ? () => _changeMonth(provider.nextMonth)
              : null,
        ),
      ],
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    BudgetsProvider provider,
    bool hideAmounts,
  ) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;

    if (provider.isLoading && !provider.hasLoadedMonth) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: SureSpacing.huge * 3),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    switch (provider.error) {
      case BudgetsLoadError.offline:
        return [
          _message(
            context,
            icon: Icons.cloud_off_outlined,
            title: l.budgetsOfflineTitle,
            body: l.budgetsOfflineMessage,
            onRetry: () => _load(forceRefresh: true),
          ),
        ];
      case BudgetsLoadError.unauthorized:
        return [
          _message(
            context,
            icon: Icons.lock_outline,
            title: l.budgetsLoadFailed,
            body: l.budgetsSessionExpired,
          ),
        ];
      case BudgetsLoadError.failed:
        return [
          _message(
            context,
            icon: Icons.error_outline,
            title: l.budgetsLoadFailed,
            body: provider.errorMessage,
            onRetry: () => _load(forceRefresh: true),
          ),
        ];
      case null:
        break;
    }

    if (!provider.hasLoadedMonth) return const [];

    final budget = provider.budget;
    if (budget == null) {
      final locale = Localizations.localeOf(context).toString();
      return [
        _message(
          context,
          icon: Icons.pie_chart_outline,
          title: l.budgetsNoBudgetTitle(
            DateFormat.yMMMM(locale).format(provider.month),
          ),
          body: l.budgetsNoBudgetMessage,
        ),
      ];
    }

    final widgets = <Widget>[];

    if (provider.showingCachedWhileOffline) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: SureSpacing.lg),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 16, color: palette.textSecondary),
              const SizedBox(width: SureSpacing.sm),
              Expanded(
                child: Text(
                  l.budgetsOfflineCached,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: palette.textSecondary),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (provider.monthBudgets.length > 1) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: SureSpacing.lg),
          child: Wrap(
            spacing: SureSpacing.md,
            runSpacing: SureSpacing.md,
            children: [
              for (var i = 0; i < provider.monthBudgets.length; i++)
                SureChip(
                  label: l.budgetsBudgetNumber(i + 1),
                  selected: provider.monthBudgets[i].id == budget.id,
                  onSelected: (_) => _selectBudget(provider.monthBudgets[i].id),
                ),
            ],
          ),
        ),
      );
    }

    if (provider.isLoading) {
      widgets.add(const LinearProgressIndicator(minHeight: 2));
      widgets.add(const SizedBox(height: SureSpacing.md));
    }

    widgets.add(BudgetSummaryCard(budget: budget, hideAmounts: hideAmounts));

    if (!budget.initialized) {
      widgets.add(const SizedBox(height: SureSpacing.lg));
      widgets.add(
        _message(
          context,
          icon: Icons.tune,
          title: null,
          body: l.budgetsNotSetUpMessage,
        ),
      );
    }

    widgets.addAll(_buildCategories(context, provider, budget, hideAmounts));
    return widgets;
  }

  List<Widget> _buildCategories(
    BuildContext context,
    BudgetsProvider provider,
    Budget budget,
    bool hideAmounts,
  ) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final groups = provider.visibleGroups;
    final overCount = provider.overBudgetCount;
    final filter = overCount == 0 ? _CategoryFilter.all : _filter;

    final rows = <Widget>[];
    void addRow(BudgetCategory bc, List<String> ids, {bool indented = false}) {
      if (rows.isNotEmpty) {
        rows.add(Divider(height: 1, color: palette.borderSecondary));
      }
      rows.add(
        BudgetCategoryRow(
          key: ValueKey('budget-category-${bc.id}'),
          budgetCategory: bc,
          hideAmounts: hideAmounts,
          indented: indented,
          onTap: () => _openCategory(budget, bc, ids),
        ),
      );
    }

    for (final group in groups) {
      if (filter == _CategoryFilter.overBudget) {
        if (group.parent.isOverBudget) {
          addRow(group.parent, group.categoryIds);
        }
        for (final child in group.children.where((c) => c.isOverBudget)) {
          addRow(child, [child.category.id]);
        }
      } else {
        addRow(group.parent, group.categoryIds);
        for (final child in group.children) {
          addRow(child, [child.category.id], indented: true);
        }
      }
    }

    return [
      const SizedBox(height: SureSpacing.xxxl),
      Padding(
        padding: const EdgeInsets.only(bottom: SureSpacing.md),
        child: Text(
          l.budgetsCategoriesTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      if (overCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: SureSpacing.lg),
          child: SureSegmentedControl<_CategoryFilter>(
            segments: [
              SureSegment(value: _CategoryFilter.all, label: l.commonAll),
              SureSegment(
                value: _CategoryFilter.overBudget,
                label: l.budgetsFilterOverBudget(overCount),
              ),
            ],
            selected: filter,
            onChanged: (value) => setState(() => _filter = value),
          ),
        ),
      if (rows.isEmpty)
        _message(
          context,
          icon: Icons.category_outlined,
          title: null,
          body: l.budgetsNoCategories,
        )
      else
        SureCard(
          padding: EdgeInsets.zero,
          child: Column(children: rows),
        ),
    ];
  }

  Widget _message(
    BuildContext context, {
    required IconData icon,
    required String? title,
    String? body,
    VoidCallback? onRetry,
  }) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(
        top: title == null ? 0 : SureSpacing.huge * 2,
      ),
      child: Column(
        children: [
          Icon(icon, size: title == null ? 32 : 56, color: palette.textSubdued),
          if (title != null) ...[
            const SizedBox(height: SureSpacing.xl),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
          ],
          if (body != null && body.isNotEmpty) ...[
            const SizedBox(height: SureSpacing.md),
            Text(
              body,
              textAlign: TextAlign.center,
              style:
                  textTheme.bodyMedium?.copyWith(color: palette.textSecondary),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: SureSpacing.xl),
            SureButton(
              label: l.commonTryAgain,
              onPressed: onRetry,
              variant: SureButtonVariant.outline,
              size: SureButtonSize.sm,
            ),
          ],
        ],
      ),
    );
  }
}
