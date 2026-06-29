import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../models/offline_transaction.dart';
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../screens/transaction_edit_screen.dart';
import '../screens/transaction_form_screen.dart';
import '../widgets/account_detail_header.dart';
import '../widgets/category_filter.dart';
import '../widgets/sure_dialog.dart';
import '../widgets/sync_status_badge.dart';
import '../services/log_service.dart';
import '../theme/sure_tokens.dart';
import '../utils/amount_parser.dart';
import '../widgets/money_text.dart';
import '../l10n/app_localizations.dart';

class TransactionsListScreen extends StatefulWidget {
  final Account account;

  const TransactionsListScreen({
    super.key,
    required this.account,
  });

  @override
  State<TransactionsListScreen> createState() => _TransactionsListScreenState();
}

class _TransactionsListScreenState extends State<TransactionsListScreen> {
  bool _isSelectionMode = false;
  final Set<String> _selectedTransactions = {};
  Set<String> _selectedCategoryIds = {};

  @override
  void initState() {
    super.initState();
    _loadTransactions();
    _loadCategories();
  }

  // Parse and display amount information
  // Amount is a currency-formatted string returned by the API (e.g. may include
  // currency symbol, grouping separators, locale-dependent decimal separator,
  // and a sign either before or after the symbol)
  Map<String, dynamic> _getAmountDisplayInfo(
    String amount,
    bool isAsset,
    bool isLiability,
  ) {
    try {
      final parsed = AmountParser.parse(amount);
      var numericValue = parsed.value;

      // For asset and liability accounts, flip the sign to match accounting conventions
      if (isAsset || isLiability) {
        numericValue = -numericValue;
      }

      // Determine if the final value is positive
      bool isPositive = numericValue >= 0;
      final trend = isPositive ? MoneyTrend.inflow : MoneyTrend.outflow;

      return {
        'isPositive': isPositive,
        'displayAmount': parsed.displayText,
        'trend': trend,
        'color': SureMoney.color(context, trend),
        'icon': isPositive ? Icons.arrow_upward : Icons.arrow_downward,
        'prefix': isPositive ? '' : '-',
      };
    } on FormatException {
      LogService.instance.error('TransactionsListScreen', 'Failed to parse transaction amount');
      return {
        'isPositive': true,
        'displayAmount': amount,
        'trend': MoneyTrend.neutral,
        'color': SureMoney.color(context, MoneyTrend.neutral),
        'icon': Icons.help_outline,
        'prefix': '',
      };
    }
  }

  Future<void> _loadCategories() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final categoriesProvider = Provider.of<CategoriesProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken != null) {
      await categoriesProvider.fetchCategories(accessToken: accessToken);
    }
  }

  String? _getCategoryDisplayName(String? categoryId, String? fallbackName) {
    if (categoryId == null) return fallbackName;
    final categoriesProvider = Provider.of<CategoriesProvider>(context);
    for (final cat in categoriesProvider.categories) {
      if (cat.id == categoryId) return cat.displayName;
    }
    return fallbackName;
  }

  List<OfflineTransaction> _getFilteredTransactions(List<OfflineTransaction> transactions) {
    if (_selectedCategoryIds.isEmpty) return transactions;
    return transactions.where((t) =>
      t.categoryId != null && _selectedCategoryIds.contains(t.categoryId)
    ).toList();
  }

  Future<void> _loadTransactions() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).transactionsListAuthFailed),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    await transactionsProvider.fetchTransactions(
      accessToken: accessToken,
      accountId: widget.account.id,
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedTransactions.clear();
      }
    });
  }

  void _toggleTransactionSelection(String transactionId) {
    setState(() {
      if (_selectedTransactions.contains(transactionId)) {
        _selectedTransactions.remove(transactionId);
      } else {
        _selectedTransactions.add(transactionId);
      }
    });
  }

  Future<void> _deleteSelectedTransactions() async {
    if (_selectedTransactions.isEmpty) return;
    final l = AppLocalizations.of(context);

    final confirmed = await SureDialog.confirm(
      context,
      title: l.transactionsListDeleteMultiTitle,
      message: l.transactionsListDeleteMultiContent,
      confirmLabel: l.commonDelete,
      cancelLabel: l.commonCancel,
      destructive: true,
    );

    if (confirmed != true || !mounted) return;

    final count = _selectedTransactions.length;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken != null) {
      final success = await transactionsProvider.deleteMultipleTransactions(
        accessToken: accessToken,
        transactionIds: _selectedTransactions.toList(),
      );

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.transactionsListDeletedMulti(count)),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {
            _selectedTransactions.clear();
            _isSelectionMode = false;
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.transactionsListDeleteFailed),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _undoTransaction(OfflineTransaction transaction) async {
    final l = AppLocalizations.of(context);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final isPending = transaction.syncStatus == SyncStatus.pending;

    final confirmed = await SureDialog.confirm(
      context,
      title: l.transactionsListUndoTitle,
      message: isPending
          ? l.transactionsListUndoRemovePending
          : l.transactionsListUndoRestoreConfirm,
      confirmLabel: l.commonUndo,
      cancelLabel: l.commonCancel,
    );

    if (confirmed != true) return;

    final success = await transactionsProvider.undoPendingTransaction(
      localId: transaction.localId,
      syncStatus: transaction.syncStatus,
    );

    if (mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? (isPending
                    ? l.transactionsListUndoPendingRemoved
                    : l.transactionsListUndoRestored)
                : l.transactionsListUndoFailed,
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _editTransaction(OfflineTransaction transaction) async {
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => TransactionEditScreen(transaction: transaction),
      ),
    );

    if (updated == true && mounted) {
      await _loadTransactions();
    }
  }

  Future<bool> _confirmAndDeleteTransaction(Transaction transaction) async {
    if (transaction.id == null) return false;

    // Show confirmation dialog
    // Capture providers and localizations before async gap
    final l = AppLocalizations.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);

    final confirmed = await SureDialog.confirm(
      context,
      title: l.transactionsListDeleteTitle,
      message: l.transactionsListDeleteSingleContent(transaction.name),
      confirmLabel: l.commonDelete,
      cancelLabel: l.commonCancel,
      destructive: true,
    );

    if (confirmed != true) return false;

    // Perform the deletion
    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken == null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l.transactionsListDeleteNoToken),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }

    final success = await transactionsProvider.deleteTransaction(
      accessToken: accessToken,
      transactionId: transaction.id!,
    );

    if (mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? l.transactionsListDeletedSuccess
                : l.transactionsListSingleDeleteFailed,
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }

    return success;
  }

  void _showAddTransactionForm() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TransactionFormScreen(account: widget.account),
    ).then((_) {
      if (mounted) {
        _loadTransactions();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.account.name),
        actions: [
          if (_isSelectionMode)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _selectedTransactions.isEmpty ? null : _deleteSelectedTransactions,
            ),
          IconButton(
            icon: Icon(_isSelectionMode ? Icons.close : Icons.checklist),
            onPressed: _toggleSelectionMode,
          ),
        ],
      ),
      body: Column(
        children: [
          AccountDetailHeader(account: widget.account),
          Expanded(
            child: Consumer<TransactionsProvider>(
              builder: (context, transactionsProvider, child) {
          if (transactionsProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (transactionsProvider.error != null) {
            return RefreshIndicator(
              onRefresh: _loadTransactions,
              child: CustomScrollView(
                slivers: [
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline, size: 48, color: Colors.red),
                          const SizedBox(height: 16),
                          Text(
                            transactionsProvider.error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _loadTransactions,
                            child: Text(l.transactionsListRetry),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final allTransactions = transactionsProvider.offlineTransactions;

          if (allTransactions.isEmpty) {
            return RefreshIndicator(
              onRefresh: _loadTransactions,
              child: CustomScrollView(
                slivers: [
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 64,
                            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l.transactionsListNoTransactionsYet,
                            style: TextStyle(
                              fontSize: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l.transactionsListEmptyAddFirst,
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final transactions = _getFilteredTransactions(allTransactions);

          return RefreshIndicator(
            onRefresh: _loadTransactions,
            child: Column(
              children: [
                Consumer<CategoriesProvider>(
                  builder: (context, categoriesProvider, _) {
                    if (categoriesProvider.isLoading || categoriesProvider.categories.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: CategoryFilter(
                        availableCategories: categoriesProvider.categories,
                        selectedCategoryIds: _selectedCategoryIds,
                        onSelectionChanged: (categoryIds) {
                          setState(() {
                            _selectedCategoryIds = categoryIds;
                          });
                        },
                      ),
                    );
                  },
                ),
                Expanded(
                  child: transactions.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.4,
                            child: Center(
                              child: Text(
                                l.transactionsListNoCategoryMatch,
                                style: TextStyle(color: colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: transactions.length,
              itemBuilder: (context, index) {
                final transaction = transactions[index];
                final isSelected = transaction.id != null &&
                    _selectedTransactions.contains(transaction.id);
                final isPending = transaction.syncStatus == SyncStatus.pending;
                final isPendingDelete = transaction.syncStatus == SyncStatus.pendingDelete;
                final isFailed = transaction.syncStatus == SyncStatus.failed;
                final hasPendingStatus = isPending || isPendingDelete;

                // Compute display info once to avoid duplicate parsing
                final displayInfo = _getAmountDisplayInfo(
                  transaction.amount,
                  widget.account.isAsset,
                  widget.account.isLiability,
                );

                return Dismissible(
                  key: Key(transaction.id ?? 'transaction_$index'),
                  direction: _isSelectionMode
                      ? DismissDirection.none
                      : DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (direction) => _confirmAndDeleteTransaction(transaction),
                  child: Opacity(
                    opacity: hasPendingStatus ? 0.5 : 1.0,
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        onTap: _isSelectionMode && transaction.id != null
                            ? () => _toggleTransactionSelection(transaction.id!)
                            : null,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                            if (_isSelectionMode)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Checkbox(
                                  value: isSelected,
                                  onChanged: transaction.id != null
                                      ? (value) => _toggleTransactionSelection(transaction.id!)
                                      : null,
                                ),
                              ),
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: (displayInfo['color'] as Color).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                displayInfo['icon'] as IconData,
                                color: displayInfo['color'] as Color,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          transaction.name,
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                fontWeight: SureTokens.weightMedium,
                                              ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (transaction.categoryName != null) ...[
                                        const SizedBox(width: 8),
                                        Flexible(
                                          flex: 0,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(
                                                color: colorScheme.primary.withValues(alpha: 0.3),
                                              ),
                                            ),
                                            child: Text(
                                              _getCategoryDisplayName(transaction.categoryId, transaction.categoryName) ?? '',
                                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                    color: colorScheme.onPrimaryContainer,
                                                    fontWeight: SureTokens.weightMedium,
                                                  ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    transaction.date,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  if (transaction.merchantName != null ||
                                      transaction.tagNames.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        if (transaction.merchantName != null)
                                          Chip(
                                            label: Text(transaction.merchantName!),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                        ...transaction.tagNames
                                            .where((name) => name.isNotEmpty)
                                            .map(
                                              (name) => Chip(
                                                label: Text(name),
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                            ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (hasPendingStatus || isFailed)
                                      Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: SyncStatusBadge(
                                          syncStatus: transaction.syncStatus,
                                          compact: true,
                                        ),
                                      ),
                                    if (!_isSelectionMode &&
                                        transaction.syncStatus ==
                                            SyncStatus.synced)
                                      SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: IconButton(
                                          icon: const Icon(Icons.edit),
                                          tooltip: l.transactionsListEditTooltip,
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          onPressed: () =>
                                              _editTransaction(transaction),
                                        ),
                                      ),
                                    Flexible(
                                      child: MoneyText(
                                        '${displayInfo['prefix']}${displayInfo['displayAmount']}',
                                        trend: displayInfo['trend'] as MoneyTrend,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                              fontWeight: SureTokens.weightMedium,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (hasPendingStatus) ...[
                                  const SizedBox(height: 4),
                                  InkWell(
                                    onTap: () => _undoTransaction(transaction),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.blue.withValues(alpha: 0.3),
                                          width: 1,
                                        ),
                                      ),
                                      child: const Text(
                                        'Undo',
                                        style: TextStyle(
                                          color: Colors.blue,
                                          fontSize: 11,
                                          fontWeight: SureTokens.weightSemibold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  transaction.currency,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
                ),
              ],
            ),
          );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddTransactionForm,
        child: const Icon(Icons.add),
      ),
    );
  }
}
