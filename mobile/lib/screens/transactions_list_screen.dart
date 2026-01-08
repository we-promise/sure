import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/auth_provider.dart';
import '../providers/transactions_provider.dart';
import '../screens/transaction_form_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadTransactions();
  }

  // Parse and display amount information
  // Amount is a currency-formatted string returned by the API (e.g. may include
  // currency symbol, grouping separators, locale-dependent decimal separator,
  // and a sign either before or after the symbol)
  Map<String, dynamic> _getAmountDisplayInfo(String amount, bool isAsset) {
    try {
      // Trim whitespace
      String trimmedAmount = amount.trim();

      // Normalize common minus characters (U+002D HYPHEN-MINUS, U+2212 MINUS SIGN)
      trimmedAmount = trimmedAmount.replaceAll('\u2212', '-');

      // Detect if the amount has a negative sign (leading or trailing)
      bool hasNegativeSign = trimmedAmount.startsWith('-') || trimmedAmount.endsWith('-');

      // Remove all non-numeric characters except decimal point and minus sign
      String numericString = trimmedAmount.replaceAll(RegExp(r'[^\d.\-]'), '');

      // Parse the numeric value
      double numericValue = double.tryParse(numericString.replaceAll('-', '')) ?? 0.0;

      // Apply the sign from the string
      if (hasNegativeSign) {
        numericValue = -numericValue;
      }

      // For asset accounts, flip the sign to match accounting conventions
      if (isAsset) {
        numericValue = -numericValue;
      }

      // Determine if the final value is positive
      bool isPositive = numericValue >= 0;

      // Get the display amount by removing the sign and currency symbols
      String displayAmount = trimmedAmount
          .replaceAll('-', '')
          .replaceAll('\u2212', '')
          .trim();

      return {
        'isPositive': isPositive,
        'displayAmount': displayAmount,
        'color': isPositive ? Colors.green : Colors.red,
        'icon': isPositive ? Icons.arrow_upward : Icons.arrow_downward,
        'prefix': isPositive ? '' : '-',
      };
    } catch (e) {
      // Fallback if parsing fails - log and return neutral state
      debugPrint('Failed to parse amount "$amount": $e');
      return {
        'isPositive': true,
        'displayAmount': amount,
        'color': Colors.grey,
        'icon': Icons.help_outline,
        'prefix': '',
      };
    }
  }

  Future<void> _loadTransactions() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed: Please log in again'),
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Transactions'),
        content: Text('Are you sure you want to delete ${_selectedTransactions.length} transaction(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

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
              content: Text('Deleted ${_selectedTransactions.length} transaction(s)'),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {
            _selectedTransactions.clear();
            _isSelectionMode = false;
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to delete transactions'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<bool> _confirmAndDeleteTransaction(Transaction transaction) async {
    if (transaction.id == null) return false;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Transaction'),
        content: Text('Are you sure you want to delete "${transaction.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return false;

    // Perform the deletion
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken == null) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Failed to delete: No access token'),
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
          content: Text(success ? 'Transaction deleted' : 'Failed to delete transaction'),
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
      body: Consumer<TransactionsProvider>(
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
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final transactions = transactionsProvider.transactions;

          if (transactions.isEmpty) {
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
                            'No transactions yet',
                            style: TextStyle(
                              fontSize: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap + to add your first transaction',
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

          return RefreshIndicator(
            onRefresh: _loadTransactions,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: transactions.length,
              itemBuilder: (context, index) {
                final transaction = transactions[index];
                final isSelected = transaction.id != null &&
                    _selectedTransactions.contains(transaction.id);
                // Compute display info once to avoid duplicate parsing
                final displayInfo = _getAmountDisplayInfo(
                  transaction.amount,
                  widget.account.isAsset,
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
                                  Text(
                                    transaction.name,
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    transaction.date,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${displayInfo['prefix']}${displayInfo['displayAmount']}',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: displayInfo['color'] as Color,
                                      ),
                                ),
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
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddTransactionForm,
        child: const Icon(Icons.add),
      ),
    );
  }
}
