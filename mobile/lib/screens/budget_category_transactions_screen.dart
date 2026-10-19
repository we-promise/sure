import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/accounts_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/budgets_service.dart';
import '../services/transactions_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import '../widgets/money_text.dart';
import '../widgets/sure_button.dart';

/// Transactions behind one budget line: the category (and, for a parent, its
/// subcategories) within the budget's date range, newest first, paged from
/// `GET /api/v1/transactions` with `category_ids[]`, `start_date` and
/// `end_date`.
class BudgetCategoryTransactionsScreen extends StatefulWidget {
  const BudgetCategoryTransactionsScreen({
    super.key,
    required this.title,
    required this.periodLabel,
    required this.categoryIds,
    required this.startDate,
    required this.endDate,
    this.service,
    this.accessTokenLoader,
  });

  final String title;
  final String periodLabel;
  final List<String> categoryIds;
  final DateTime startDate;
  final DateTime endDate;

  /// Injected for tests.
  final TransactionsService? service;
  final Future<String?> Function()? accessTokenLoader;

  @override
  State<BudgetCategoryTransactionsScreen> createState() =>
      _BudgetCategoryTransactionsScreenState();
}

class _BudgetCategoryTransactionsScreenState
    extends State<BudgetCategoryTransactionsScreen> {
  static const int _perPage = 50;

  late final TransactionsService _service =
      widget.service ?? TransactionsService();
  final List<Transaction> _transactions = [];
  int _page = 0;
  int _totalPages = 1;
  bool _loading = false;
  bool _failed = false;

  /// Whether the request that failed was a reload from page one, so its retry
  /// repeats it instead of appending the next page to stale rows.
  bool _failedWasReset = false;

  bool get _hasMore => _page < _totalPages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPage(reset: true));
  }

  Future<String?> _accessToken() {
    final loader = widget.accessTokenLoader;
    if (loader != null) return loader();
    return context.read<AuthProvider>().getValidAccessToken();
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });

    final token = await _accessToken();
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _loading = false;
        _failed = true;
        _failedWasReset = reset;
      });
      return;
    }

    final nextPage = reset ? 1 : _page + 1;
    final result = await _service.getTransactions(
      accessToken: token,
      categoryIds: widget.categoryIds,
      startDate: BudgetsService.formatApiDate(widget.startDate),
      endDate: BudgetsService.formatApiDate(widget.endDate),
      page: nextPage,
      perPage: _perPage,
    );
    if (!mounted) return;

    setState(() {
      _loading = false;
      if (result['success'] == true) {
        if (reset) _transactions.clear();
        _transactions.addAll(result['transactions'] as List<Transaction>);
        _page = nextPage;
        final pagination = result['pagination'];
        _totalPages = pagination is Map
            ? (pagination['total_pages'] as num?)?.toInt() ?? nextPage
            : nextPage;
      } else {
        _failed = true;
        _failedWasReset = reset;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final hideAmounts = context.watch<PrivacyProvider>().hidden;

    Widget body;
    if (_loading && _transactions.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failed && _transactions.isEmpty) {
      body = _centered(
        context,
        Icons.error_outline,
        l.budgetCategoryTransactionsLoadFailed,
        action: SureButton(
          label: l.commonTryAgain,
          onPressed: () => _loadPage(reset: true),
          variant: SureButtonVariant.outline,
          size: SureButtonSize.sm,
        ),
      );
    } else if (_transactions.isEmpty) {
      body = _centered(
        context,
        Icons.receipt_long_outlined,
        l.budgetCategoryTransactionsEmpty(widget.periodLabel),
      );
    } else {
      body = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _transactions.length + (_hasMore || _failed ? 1 : 0),
        separatorBuilder: (_, __) =>
            Divider(height: 1, color: palette.borderSecondary),
        itemBuilder: (context, index) {
          if (index >= _transactions.length) {
            return Padding(
              padding: const EdgeInsets.all(SureSpacing.xl),
              child: Center(
                child: SureButton(
                  label: _failed
                      ? l.commonTryAgain
                      : l.budgetCategoryTransactionsLoadMore,
                  onPressed: _loading
                      ? null
                      : () => _loadPage(reset: _failed && _failedWasReset),
                  loading: _loading,
                  variant: SureButtonVariant.outline,
                  size: SureButtonSize.sm,
                ),
              ),
            );
          }
          return _TransactionTile(
            transaction: _transactions[index],
            hideAmounts: hideAmounts,
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            Text(
              widget.periodLabel,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: palette.textSecondary),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadPage(reset: true),
        child: body,
      ),
    );
  }

  Widget _centered(
    BuildContext context,
    IconData icon,
    String message, {
    Widget? action,
  }) {
    final palette = SureColors.of(context).palette;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(SureSpacing.xxxl),
      children: [
        const SizedBox(height: SureSpacing.huge * 2),
        Icon(icon, size: 56, color: palette.textSubdued),
        const SizedBox(height: SureSpacing.xl),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: palette.textSecondary),
        ),
        if (action != null) ...[
          const SizedBox(height: SureSpacing.xl),
          Center(child: action),
        ],
      ],
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({
    required this.transaction,
    required this.hideAmounts,
  });

  final Transaction transaction;
  final bool hideAmounts;

  Account? _account(BuildContext context) {
    try {
      final accounts = context.read<AccountsProvider>().accounts;
      for (final account in accounts) {
        if (account.id == transaction.accountId) return account;
      }
    } on ProviderNotFoundException {
      // Account names are optional context; the tile still renders.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toString();
    final isIncome = transaction.nature == 'income';
    final trend = isIncome ? MoneyTrend.inflow : MoneyTrend.outflow;
    final magnitude =
        transaction.amount.replaceFirst(RegExp('^[-\u2212+]'), '');
    final amount = '${isIncome ? '+' : '-'}$magnitude';

    final date = DateTime.tryParse(transaction.date);
    final subtitleParts = <String>[
      if (date != null) DateFormat.yMMMd(locale).format(date),
      if (_account(context)?.name case final String name) name,
      if (transaction.categoryName case final String category) category,
    ];

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: SureSpacing.xl,
        vertical: SureSpacing.xs,
      ),
      title: Text(
        transaction.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyLarge?.copyWith(
          fontWeight: SureTokens.weightMedium,
        ),
      ),
      subtitle: Text(
        subtitleParts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(color: palette.textSecondary),
      ),
      trailing: MoneyText(
        MoneyMasker.mask(amount, hidden: hideAmounts),
        trend: trend,
        style: textTheme.bodyLarge?.copyWith(
          fontWeight: SureTokens.weightMedium,
        ),
      ),
    );
  }
}
