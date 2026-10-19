import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/cash_flow.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/cash_flow_service.dart';
import '../services/connectivity_service.dart';
import '../services/transactions_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import '../widgets/cash_flow_donut_chart.dart';
import '../widgets/money_text.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_card.dart';
import '../widgets/sure_chip.dart';
import '../widgets/sure_icon.dart';
import '../widgets/sure_list_group.dart';
import '../widgets/sure_segmented_control.dart';
import 'cash_flow_category_transactions_screen.dart';

/// Loads an access token. Defaults to [AuthProvider.getValidAccessToken];
/// injectable so widget tests don't need the secure-storage backed provider.
typedef AccessTokenLoader = Future<String?> Function(BuildContext context);

/// Cash flow report: income vs expenses vs net savings for a period, plus
/// expenses (or income) by category as a donut chart and a ranked list with
/// each category's share. Tapping a category opens its transactions for the
/// period. Mobile counterpart of the web dashboard's cash flow Sankey and
/// outflows donut; all totals come from `GET /api/v1/cash_flow`.
///
/// The report is server-calculated, so it needs a connection. Reports already
/// loaded in this screen stay visible (flagged "Outdated") when a refresh
/// fails or the device goes offline, mirroring the net worth card.
class CashFlowScreen extends StatefulWidget {
  const CashFlowScreen({
    super.key,
    this.service,
    this.transactionsService,
    this.accessTokenLoader,
    this.clock,
    this.initialPeriod = CashFlowPeriod.currentMonth,
  });

  final CashFlowService? service;

  /// Passed to the category drill-down screen.
  final TransactionsService? transactionsService;
  final AccessTokenLoader? accessTokenLoader;

  /// Source of "today" for period ranges; injectable for tests.
  final DateTime Function()? clock;
  final CashFlowPeriod initialPeriod;

  @override
  State<CashFlowScreen> createState() => _CashFlowScreenState();
}

class _CashFlowScreenState extends State<CashFlowScreen> {
  late final CashFlowService _service = widget.service ?? CashFlowService();
  late CashFlowPeriod _period = widget.initialPeriod;
  CashFlowSide _side = CashFlowSide.expense;

  final Map<CashFlowPeriod, CashFlowReport> _reports = {};

  /// The date range each cached report was fetched for. A preset such as
  /// "This month" moves when the date changes, so a cached report only
  /// counts while its range still matches.
  final Map<CashFlowPeriod, CashFlowDateRange> _reportRanges = {};
  final Set<CashFlowPeriod> _stale = {};
  bool _loading = false;
  bool _offline = false;
  bool _failed = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  CashFlowDateRange _rangeFor(CashFlowPeriod period) =>
      period.rangeFor((widget.clock ?? DateTime.now)());

  Future<String?> _accessToken() {
    final loader = widget.accessTokenLoader;
    if (loader != null) return loader(context);
    return context.read<AuthProvider>().getValidAccessToken();
  }

  ConnectivityService? _connectivity() {
    try {
      return Provider.of<ConnectivityService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _load({bool force = false}) async {
    final period = _period;
    final range = _rangeFor(period);
    if (!force &&
        _reports.containsKey(period) &&
        !_stale.contains(period) &&
        _reportRanges[period] == range) {
      return;
    }
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _failed = false;
      _offline = false;
    });

    final offline = _connectivity()?.isOffline ?? false;
    Map<String, dynamic>? result;
    try {
      final token = offline ? null : await _accessToken();
      if (token != null) {
        result = await _service.getCashFlow(accessToken: token, range: range);
      }
    } catch (_) {
      // A failed token refresh (or storage error) is a failed load.
      result = null;
    }
    if (!mounted || requestId != _requestId) return;

    setState(() {
      _loading = false;
      if (result != null && result['success'] == true) {
        _reports[period] = result['report'] as CashFlowReport;
        _reportRanges[period] = range;
        _stale.remove(period);
      } else {
        _offline = offline;
        _failed = !offline;
        if (_reports.containsKey(period)) _stale.add(period);
      }
    });
  }

  void _selectPeriod(CashFlowPeriod period) {
    if (period == _period) return;
    setState(() => _period = period);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final report = _reports[_period];

    return Scaffold(
      appBar: AppBar(title: Text(l.cashFlowTitle)),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          // Keep pull-to-refresh available even when content is short.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            SureSpacing.xl,
            SureSpacing.md,
            SureSpacing.xl,
            SureSpacing.huge,
          ),
          children: [
            _PeriodSelector(selected: _period, onSelected: _selectPeriod),
            const SizedBox(height: SureSpacing.xl),
            if (report == null)
              _buildPlaceholder(context)
            else ...[
              _SummaryCard(
                report: report,
                stale: _stale.contains(_period),
              ),
              const SizedBox(height: SureSpacing.xl),
              if (report.isEmpty)
                _MessageState(
                  icon: SureIcons.receipt,
                  title: l.cashFlowEmpty,
                  subtitle: l.cashFlowEmptySubtitle,
                )
              else ...[
                SureSegmentedControl<CashFlowSide>(
                  selected: _side,
                  onChanged: (side) => setState(() => _side = side),
                  segments: [
                    SureSegment(
                      value: CashFlowSide.expense,
                      label: l.cashFlowExpenses,
                    ),
                    SureSegment(
                      value: CashFlowSide.income,
                      label: l.cashFlowIncome,
                    ),
                  ],
                ),
                const SizedBox(height: SureSpacing.xl),
                _CategoryBreakdown(
                  report: report,
                  side: _side,
                  onCategoryTap: (category) => _openCategory(report, category),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: SureSpacing.huge * 2),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_offline || _failed) {
      return _MessageState(
        icon: SureIcons.circleAlert,
        title: l.cashFlowLoadFailed,
        subtitle: _offline ? l.cashFlowOffline : null,
        action: SureButton(
          label: l.commonTryAgain,
          onPressed: () => _load(force: true),
          leading: const SureIcon(SureIcons.refresh, size: 18),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  void _openCategory(CashFlowReport report, CashFlowCategory category) {
    if (!category.canDrillDown) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CashFlowCategoryTransactionsScreen(
          category: category,
          range: CashFlowDateRange(report.startDate, report.endDate),
          service: widget.transactionsService,
          accessTokenLoader: widget.accessTokenLoader,
        ),
      ),
    );
  }
}

/// Shared money/percent formatting for the cash flow widgets.
class CashFlowFormat {
  const CashFlowFormat._();

  static String money(BuildContext context, double amount, String currency) {
    final locale = Localizations.localeOf(context).toString();
    try {
      return NumberFormat.simpleCurrency(
        locale: locale,
        name: currency.isEmpty ? null : currency,
      ).format(amount);
    } catch (_) {
      return '${amount.toStringAsFixed(2)} $currency';
    }
  }

  /// [percent] is in percentage points (e.g. `24.5` -> `24.5%`).
  static String percent(BuildContext context, double percent) {
    final locale = Localizations.localeOf(context).toString();
    return NumberFormat.decimalPercentPattern(locale: locale, decimalDigits: 1)
        .format(percent / 100);
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.selected, required this.onSelected});

  final CashFlowPeriod selected;
  final ValueChanged<CashFlowPeriod> onSelected;

  static String label(AppLocalizations l, CashFlowPeriod period) {
    switch (period) {
      case CashFlowPeriod.currentMonth:
        return l.cashFlowPeriodCurrentMonth;
      case CashFlowPeriod.lastMonth:
        return l.cashFlowPeriodLastMonth;
      case CashFlowPeriod.last30Days:
        return l.cashFlowPeriodLast30Days;
      case CashFlowPeriod.last90Days:
        return l.cashFlowPeriodLast90Days;
      case CashFlowPeriod.currentYear:
        return l.cashFlowPeriodCurrentYear;
      case CashFlowPeriod.last365Days:
        return l.cashFlowPeriodLast365Days;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final period in CashFlowPeriod.values) ...[
            if (period != CashFlowPeriod.values.first)
              const SizedBox(width: SureSpacing.md),
            SureChip(
              key: ValueKey('cashFlowPeriod_${period.name}'),
              label: label(l, period),
              selected: period == selected,
              onSelected: (_) => onSelected(period),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report, required this.stale});

  final CashFlowReport report;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    final hidden = context.watch<PrivacyProvider>().hidden;
    String money(double v) => MoneyMasker.mask(
          CashFlowFormat.money(context, v, report.currency),
          hidden: hidden,
        );
    final locale = Localizations.localeOf(context).toString();
    final dates = DateFormat.yMMMd(locale);
    final rate = report.savingsRate;

    return SureCard(
      key: const ValueKey('cashFlowSummary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${dates.format(report.startDate)} – ${dates.format(report.endDate)}',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: palette.textSecondary),
                ),
              ),
              if (stale)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SureSpacing.sm,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surfaceInset,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l.cashFlowOutdated,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.textSubdued,
                      fontWeight: SureTokens.weightMedium,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: SureSpacing.lg),
          Text(
            l.cashFlowNetSavings,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: SureSpacing.xs),
          MoneyText(
            money(report.netSavings),
            trend:
                report.netSavings < 0 ? MoneyTrend.outflow : MoneyTrend.inflow,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: SureTokens.weightMedium),
          ),
          if (rate != null) ...[
            const SizedBox(height: 2),
            Text(
              l.cashFlowSavingsRate(
                MoneyMasker.mask(
                  CashFlowFormat.percent(context, rate),
                  hidden: hidden,
                ),
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: palette.textSecondary),
            ),
          ],
          const SizedBox(height: SureSpacing.lg),
          Divider(height: 1, color: palette.borderSecondary),
          const SizedBox(height: SureSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _SummaryStat(
                  label: l.cashFlowIncome,
                  value: money(report.income),
                  trend: MoneyTrend.inflow,
                ),
              ),
              const SizedBox(width: SureSpacing.lg),
              Expanded(
                child: _SummaryStat(
                  label: l.cashFlowExpenses,
                  value: money(report.spending),
                  trend: MoneyTrend.outflow,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.trend,
  });

  final String label;
  final String value;
  final MoneyTrend trend;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: palette.textSecondary),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: MoneyText(
            value,
            trend: trend,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: SureTokens.weightMedium),
          ),
        ),
      ],
    );
  }
}

class _CategoryBreakdown extends StatelessWidget {
  const _CategoryBreakdown({
    required this.report,
    required this.side,
    required this.onCategoryTap,
  });

  final CashFlowReport report;
  final CashFlowSide side;
  final ValueChanged<CashFlowCategory> onCategoryTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    final hidden = context.watch<PrivacyProvider>().hidden;
    final categories = report.categoriesFor(side);
    final isIncome = side == CashFlowSide.income;
    final title =
        isIncome ? l.cashFlowIncomeByCategory : l.cashFlowExpensesByCategory;

    if (categories.isEmpty) {
      return _MessageState(
        icon: SureIcons.shapes,
        title: isIncome ? l.cashFlowNoIncome : l.cashFlowNoExpenses,
      );
    }

    // Categories without a color of their own (e.g. Uncategorized) render
    // in the neutral subdued token, like the web's gray Uncategorized.
    Color colorAt(int i) => CashFlowDonutChart.colorFromHex(
          categories[i].color,
          palette.textSubdued,
        );
    String money(double v) => MoneyMasker.mask(
          CashFlowFormat.money(context, v, report.currency),
          hidden: hidden,
        );
    String share(double p) => MoneyMasker.mask(
          CashFlowFormat.percent(context, p),
          hidden: hidden,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SureCard(
          child: Column(
            children: [
              CashFlowDonutChart(
                key: const ValueKey('cashFlowDonut'),
                semanticLabel: title,
                segments: [
                  for (var i = 0; i < categories.length; i++)
                    DonutSegment(
                        value: categories[i].amount, color: colorAt(i)),
                ],
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isIncome ? l.cashFlowIncome : l.cashFlowExpenses,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: palette.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        money(report.totalFor(side)),
                        style: SureMoney.tabular(
                          theme.textTheme.titleLarge?.copyWith(
                            fontWeight: SureTokens.weightMedium,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SureSpacing.xl),
        SureListGroup(
          header: title,
          children: [
            for (var i = 0; i < categories.length; i++)
              SureListRow(
                key: ValueKey('cashFlowCategory_${categories[i].id}'),
                leading: _CategoryDot(color: colorAt(i)),
                title: categories[i].name,
                subtitle: isIncome
                    ? l.cashFlowShareOfIncome(share(categories[i].percentage))
                    : l.cashFlowShareOfExpenses(
                        share(categories[i].percentage)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      money(categories[i].amount),
                      style: SureMoney.tabular(
                        theme.textTheme.titleSmall?.copyWith(
                          fontWeight: SureTokens.weightMedium,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: SureSpacing.sm),
                    // Keep amounts aligned whether or not a row drills down.
                    if (categories[i].canDrillDown)
                      SureIcon(
                        SureIcons.chevronRight,
                        size: SureIconSize.md,
                        color: palette.textSubdued,
                      )
                    else
                      const SizedBox(width: SureIconSize.md),
                  ],
                ),
                onTap: categories[i].canDrillDown
                    ? () => onCategoryTap(categories[i])
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _CategoryDot extends StatelessWidget {
  const _CategoryDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: SureSpacing.huge,
        horizontal: SureSpacing.xl,
      ),
      child: Column(
        children: [
          SureIcon(icon, size: SureIconSize.xxl, color: palette.textSubdued),
          const SizedBox(height: SureSpacing.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: SureSpacing.sm),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: palette.textSecondary),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: SureSpacing.xl),
            action!,
          ],
        ],
      ),
    );
  }
}
