import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/cash_flow.dart';
import '../models/category.dart';
import '../models/transaction.dart';
import '../providers/auth_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/categories_service.dart';
import '../services/transactions_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/amount_parser.dart';
import '../utils/money_masker.dart';
import '../widgets/money_text.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_icon.dart';
import '../widgets/sure_list_group.dart';
import 'cash_flow_screen.dart' show AccessTokenLoader;

/// Transactions in one cash flow category (and its subcategories) for the
/// report period, fetched page by page from `GET /api/v1/transactions` with
/// `start_date`, `end_date` and `category_ids[]`. Refunds are included, since
/// the cash flow report nets them within the category.
///
/// Like the web's category filter, every subcategory is included, also one
/// the report leaves out because its refunds net it to zero. Its ids come
/// from `GET /api/v1/categories?parent_id=…`; if that lookup fails, the
/// subcategories named in the report are used.
class CashFlowCategoryTransactionsScreen extends StatefulWidget {
  const CashFlowCategoryTransactionsScreen({
    super.key,
    required this.category,
    required this.range,
    this.service,
    this.categoriesService,
    this.accessTokenLoader,
    this.onUnauthorized,
  });

  final CashFlowCategory category;

  /// Called on a 401; defaults to [AuthProvider.logout].
  final Future<void> Function(BuildContext context)? onUnauthorized;
  final CashFlowDateRange range;
  final TransactionsService? service;
  final CategoriesService? categoriesService;
  final AccessTokenLoader? accessTokenLoader;

  @override
  State<CashFlowCategoryTransactionsScreen> createState() =>
      _CashFlowCategoryTransactionsScreenState();
}

class _CashFlowCategoryTransactionsScreenState
    extends State<CashFlowCategoryTransactionsScreen> {
  static const int _perPage = 50;

  late final TransactionsService _service =
      widget.service ?? TransactionsService();
  late final CategoriesService _categoriesService =
      widget.categoriesService ?? CategoriesService();
  final ScrollController _scroll = ScrollController();
  final List<Transaction> _transactions = [];

  /// The category plus all of its subcategories, once the lookup succeeded.
  List<String>? _categoryIds;
  int _page = 0;
  int? _totalPages;
  bool _loading = false;
  bool _failed = false;

  /// Bumped by [_refresh]; a page response from an older generation is
  /// dropped so it can't land in the reset list.
  int _generation = 0;

  bool get _hasMore => _totalPages == null || _page < _totalPages!;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<String?> _accessToken() {
    final loader = widget.accessTokenLoader;
    if (loader != null) return loader(context);
    return context.read<AuthProvider>().getValidAccessToken();
  }

  @visibleForTesting
  Future<void> refreshForTest() => _refresh();

  @visibleForTesting
  Future<void> loadMoreForTest() => _loadMore();

  Future<void> _refresh() async {
    setState(() {
      _generation++;
      _transactions.clear();
      _page = 0;
      _totalPages = null;
      _failed = false;
      _loading = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _failed) return;
    final generation = _generation;
    final nextPage = _page + 1;
    setState(() => _loading = true);

    Map<String, dynamic>? result;
    var unauthorized = false;
    try {
      final token = await _accessToken();
      if (token != null) {
        final categoryIds = _categoryIds ?? await _lookUpCategoryIds(token);
        if (categoryIds == null) {
          unauthorized = true;
        } else {
          result = await _service.getTransactions(
            accessToken: token,
            page: nextPage,
            perPage: _perPage,
            startDate: widget.range.startIso,
            endDate: widget.range.endIso,
            categoryIds: categoryIds,
          );
          unauthorized = result['error'] == 'unauthorized';
        }
      }
    } catch (_) {
      // A failed token refresh (or storage error) is a failed page.
      result = null;
    }
    if (!mounted || generation != _generation) return;

    setState(() {
      _loading = false;
      if (result != null && result['success'] == true) {
        final page = (result['transactions'] as List).cast<Transaction>();
        _transactions.addAll(page);
        _page = nextPage;
        // GET /api/v1/transactions always returns pagination.total_pages.
        final pagination = result['pagination'];
        if (pagination is Map && pagination['total_pages'] is int) {
          _totalPages = pagination['total_pages'] as int;
        }
      } else {
        _failed = true;
      }
    });
    if (unauthorized) await _handleUnauthorized();
  }

  /// The category's id plus all of its subcategory ids. Falls back to the
  /// ids the report knows when the lookup fails, and returns `null` on 401.
  Future<List<String>?> _lookUpCategoryIds(String token) async {
    final known = widget.category.transactionCategoryIds;
    final rootId = widget.category.categoryId;
    if (rootId == null) return known;
    Map<String, dynamic> lookup;
    try {
      lookup = await _categoriesService.getCategories(
        accessToken: token,
        parentId: rootId,
        perPage: 100,
      );
    } catch (_) {
      return known;
    }
    if (lookup['error'] == 'unauthorized') return null;
    if (lookup['success'] != true) return known;
    final ids = {
      ...known,
      for (final category in (lookup['categories'] as List).cast<Category>())
        if (category.id.isNotEmpty) category.id,
    }.toList(growable: false);
    if (mounted) _categoryIds = ids;
    return ids;
  }

  Future<void> _handleUnauthorized() async {
    final handler = widget.onUnauthorized;
    if (handler != null) return handler(context);
    try {
      await context.read<AuthProvider>().logout();
    } on ProviderNotFoundException {
      // No auth provider above this screen (e.g. in isolation).
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    final hidden = context.watch<PrivacyProvider>().hidden;
    final locale = Localizations.localeOf(context).toString();
    final dates = DateFormat.yMMMd(locale);

    Widget body;
    if (_transactions.isEmpty && _loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_transactions.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(SureSpacing.xxxl),
        children: [
          const SizedBox(height: SureSpacing.huge),
          SureIcon(
            _failed ? SureIcons.circleAlert : SureIcons.receipt,
            size: SureIconSize.xxl,
            color: palette.textSubdued,
          ),
          const SizedBox(height: SureSpacing.lg),
          Text(
            _failed
                ? l.cashFlowTransactionsLoadFailed
                : l.cashFlowTransactionsEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (_failed) ...[
            const SizedBox(height: SureSpacing.xl),
            Center(
              child: SureButton(
                label: l.commonTryAgain,
                onPressed: _refresh,
                leading: const SureIcon(SureIcons.refresh, size: 18),
              ),
            ),
          ],
        ],
      );
    } else {
      body = ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          SureSpacing.xl,
          SureSpacing.md,
          SureSpacing.xl,
          SureSpacing.huge,
        ),
        children: [
          SureListGroup(
            header:
                '${dates.format(widget.range.start)} – ${dates.format(widget.range.end)}',
            children: [
              for (final transaction in _transactions)
                SureListRow(
                  title: transaction.name,
                  subtitle: _subtitle(transaction, dates),
                  trailing: _amount(context, transaction, hidden),
                ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(SureSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.all(SureSpacing.xl),
              child: Center(
                child: SureButton(
                  label: l.commonTryAgain,
                  variant: SureButtonVariant.outline,
                  onPressed: () {
                    setState(() => _failed = false);
                    _loadMore();
                  },
                ),
              ),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name)),
      body: RefreshIndicator(onRefresh: _refresh, child: body),
    );
  }

  String _subtitle(Transaction transaction, DateFormat dates) {
    final date = DateTime.tryParse(transaction.date);
    final parts = <String>[
      date == null ? transaction.date : dates.format(date),
      // Subcategory transactions show which subcategory they belong to.
      if (transaction.categoryName != null &&
          transaction.categoryName!.isNotEmpty &&
          transaction.categoryName != widget.category.name)
        transaction.categoryName!,
    ];
    return parts.join(' · ');
  }

  Widget _amount(BuildContext context, Transaction transaction, bool hidden) {
    // The API's `amount` is a formatted string whose sign follows Sure's
    // ledger convention; present it by classification instead.
    final isIncome = transaction.isIncome;
    // AmountParser's display text drops hyphen/en/em/figure dashes, minus
    // signs and accounting parentheses.
    String magnitude;
    try {
      magnitude = AmountParser.parse(transaction.amount).displayText;
    } on FormatException {
      magnitude = transaction.amount;
    }
    return MoneyText(
      MoneyMasker.mask('${isIncome ? '+' : '-'}$magnitude', hidden: hidden),
      trend: isIncome ? MoneyTrend.inflow : MoneyTrend.outflow,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: SureTokens.weightMedium),
    );
  }
}
