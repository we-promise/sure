import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../providers/transactions_provider.dart';
import '../providers/accounts_provider.dart';
import '../providers/auth_provider.dart';

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

  String _getAccountName(String accountId) {
    final accountsProvider = context.read<AccountsProvider>();
    try {
      final account = accountsProvider.accounts.firstWhere(
        (a) => a.id == accountId,
      );
      return account.name;
    } catch (e) {
      return 'Unknown Account';
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
    final colorScheme = Theme.of(context).colorScheme;
    final transactionsProvider = context.watch<TransactionsProvider>();

    final recentTransactions = _getSortedTransactions(
      transactionsProvider.transactions,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('近期交易'),
        actions: [
          PopupMenuButton<int>(
            initialValue: _transactionLimit,
            icon: const Icon(Icons.filter_list),
            tooltip: '顯示筆數',
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
                    Text('顯示 $limit 筆'),
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
                        transaction,
                        colorScheme,
                      );
                    },
                  ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
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
              '暫無交易記錄',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '下拉以重新整理',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionItem(Transaction transaction, ColorScheme colorScheme) {
    final isExpense = transaction.isExpense;
    final amount = double.tryParse(transaction.amount) ?? 0.0;
    final accountName = _getAccountName(transaction.accountId);

    Color amountColor;
    String sign;

    if (isExpense) {
      amountColor = Colors.red.shade700;
      sign = '-';
    } else {
      amountColor = Colors.green.shade700;
      sign = '+';
    }

    String formattedDate;
    try {
      final date = DateTime.parse(transaction.date);
      formattedDate = DateFormat('yyyy-MM-dd HH:mm').format(date);
    } catch (e) {
      formattedDate = transaction.date;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isExpense
              ? Colors.red.withValues(alpha: 0.1)
              : Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          isExpense ? Icons.arrow_downward : Icons.arrow_upward,
          color: amountColor,
        ),
      ),
      title: Text(
        transaction.name,
        style: const TextStyle(fontWeight: FontWeight.w500),
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
      trailing: Text(
        '$sign${transaction.currency} ${_formatAmount(amount)}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 16,
          color: amountColor,
        ),
      ),
    );
  }

  String _formatAmount(double amount) {
    final formatter = NumberFormat('#,##0.00');
    return formatter.format(amount);
  }
}
