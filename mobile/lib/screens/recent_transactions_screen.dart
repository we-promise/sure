import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../models/account.dart';
import '../providers/transactions_provider.dart';
import '../providers/accounts_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/sure_tokens.dart';
import '../providers/privacy_provider.dart';
import '../utils/amount_parser.dart';
import '../utils/money_masker.dart';
import '../widgets/money_text.dart';
import '../l10n/app_localizations.dart';

class RecentTransactionsScreen extends StatefulWidget {
  const RecentTransactionsScreen({super.key});

  @override
  State<RecentTransactionsScreen> createState() => _RecentTransactionsScreenState();
}

class _RecentTransactionsScreenState extends State<RecentTransactionsScreen> {
  int _transactionLimit = 20;
  final List<int> _limitOptions = [10, 20, 50, 100];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAllTransactions();
    });
  }

  Future<void> _loadAllTransactions() async {
    final authProvider = context.read<AuthProvider>();
    final transactionsProvider = context.read<TransactionsProvider>();

    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken != null) {
      // Load transactions for all accounts
      await transactionsProvider.fetchTransactions(
        accessToken: accessToken,
        forceSync: false,
      );
    }
  }

  Future<void> _refreshTransactions() async {
    final authProvider = context.read<AuthProvider>();
    final transactionsProvider = context.read<TransactionsProvider>();

    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken != null) {
      await transactionsProvider.fetchTransactions(
        accessToken: accessToken,
        forceSync: true,
      );
    }
  }

  Account? _getAccount(String accountId) {
    final accountsProvider = context.read<AccountsProvider>();
    try {
      return accountsProvider.accounts.firstWhere(
        (a) => a.id == accountId,
      );
    } catch (e) {
      return null;
    }
  }

  List<Transaction> _getSortedTransactions(List<Transaction> transactions) {
    final sorted = List<Transaction>.from(transactions);
    sorted.sort((a, b) {
      try {
        final dateA = DateTime.parse(a.date);
        final dateB = DateTime.parse(b.date);
        return dateB.compareTo(dateA); // Most recent first
      } catch (e) {
        return 0;
      }
    });
    return sorted.take(_transactionLimit).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final transactionsProvider = context.watch<TransactionsProvider>();
    final hideAmounts = context.watch<PrivacyProvider>().hidden;

    final recentTransactions = _getSortedTransactions(
      transactionsProvider.transactions,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l.recentTransactionsTitle),
        actions: [
          PopupMenuButton<int>(
            initialValue: _transactionLimit,
            icon: const Icon(Icons.filter_list),
            tooltip: l.recentTransactionsDisplayLimit,
            onSelected: (int value) {
              setState(() {
                _transactionLimit = value;
              });
            },
            itemBuilder: (context) => _limitOptions.map((limit) {
              return PopupMenuItem<int>(
                value: limit,
                child: Row(
                  children: [
                    if (limit == _transactionLimit)
                      Icon(Icons.check, color: colorScheme.primary, size: 20)
                    else
                      const SizedBox(width: 20),
                    const SizedBox(width: 8),
                    Text(l.recentTransactionsShowN(limit)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshTransactions,
        child: transactionsProvider.isLoading
            ? const Center(child: CircularProgressIndicator())
            : recentTransactions.isEmpty
                ? _buildEmptyState(colorScheme)
                : ListView.separated(
                    itemCount: recentTransactions.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      color: colorScheme.outlineVariant,
                    ),
                    itemBuilder: (context, index) {
                      final transaction = recentTransactions[index];
                      return _buildTransactionItem(
                        context,
                        transaction,
                        colorScheme,
                        hideAmounts,
                      );
                    },
                  ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l.recentTransactionsEmpty,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              l.recentTransactionsPullToRefresh,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionItem(BuildContext context, Transaction transaction,
      ColorScheme colorScheme, bool hideAmounts) {
    final account = _getAccount(transaction.accountId);
    final accountName = account?.name ??
        AppLocalizations.of(context).recentTransactionsUnknownAccount;

    double? amount;
    try {
      amount = AmountParser.parse(transaction.amount).value;
    } on FormatException {
      // Keep the list renderable if the server returns a malformed amount.
    }

    // For asset accounts and liability accounts, flip the sign to match accounting conventions
    if (amount != null &&
        (account?.isAsset == true || account?.isLiability == true)) {
      amount = -amount;
    }

    // Determine display properties based on final amount. The semantic color
    // comes from the Sure design-system tokens (success/destructive/subdued)
    // via MoneyTrend, instead of raw Colors.green/red.
    final isPositive = amount == null || amount >= 0;
    final moneyTrend = SureMoney.trendForAmount(amount);
    final amountColor = SureMoney.color(context, moneyTrend);
    final sign = amount == null
        ? ''
        : isPositive
            ? '+'
            : '-';

    String formattedDate;
    try {
      final date = DateTime.parse(transaction.date);
      formattedDate = DateFormat('yyyy-MM-dd HH:mm',
              Localizations.localeOf(context).toString())
          .format(date);
    } catch (e) {
      formattedDate = transaction.date;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: amountColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          amount == null
              ? Icons.help_outline
              : isPositive
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
          color: amountColor,
        ),
      ),
      title: Text(
        transaction.name,
        style: const TextStyle(fontWeight: SureTokens.weightMedium),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            accountName,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            formattedDate,
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (transaction.notes != null && transaction.notes!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              transaction.notes!,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      trailing: MoneyText(
        MoneyMasker.mask(
          amount == null
              ? transaction.amount
              : '$sign${transaction.currency} ${_formatAmount(amount.abs())}',
          hidden: hideAmounts,
        ),
        trend: moneyTrend,
        style: const TextStyle(
          fontWeight: SureTokens.weightMedium,
          fontSize: 16,
        ),
      ),
    );
  }

  String _formatAmount(double amount) {
    // Support up to 8 decimal places, but omit unnecessary trailing zeros
    final formatter = NumberFormat('#,##0.########');
    return formatter.format(amount);
  }
}
