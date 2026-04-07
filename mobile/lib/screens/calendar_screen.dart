import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/accounts_provider.dart';
import '../providers/transactions_provider.dart';
import '../providers/auth_provider.dart';
import '../services/log_service.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final LogService _log = LogService.instance;
  Account? _selectedAccount;
  DateTime _currentMonth = DateTime.now();
  Map<String, double> _dailyChanges = {};
  bool _isLoading = false;
  String _accountType = 'asset'; // 'asset' or 'liability'
  DateTime? _selectedDate; // Track selected date for tap interaction
  List<Transaction> _transactions = []; // Store transactions for filtering

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialData();
    });
  }

  Future<void> _loadInitialData() async {
    final accountsProvider = context.read<AccountsProvider>();
    final authProvider = context.read<AuthProvider>();

    final accessToken = await authProvider.getValidAccessToken();

    if (accountsProvider.accounts.isEmpty && accessToken != null) {
      await accountsProvider.fetchAccounts(
        accessToken: accessToken,
        forceSync: false,
      );
    }

    if (accountsProvider.accounts.isNotEmpty) {
      // Select first account of the selected type
      final filteredAccounts = _getFilteredAccounts(accountsProvider.accounts);
      setState(() {
        _selectedAccount = filteredAccounts.isNotEmpty ? filteredAccounts.first : null;
      });
      if (_selectedAccount != null) {
        await _loadTransactionsForAccount();
      }
    }
  }

  List<Account> _getFilteredAccounts(List<Account> accounts) {
    if (_accountType == 'asset') {
      return accounts.where((a) => a.isAsset).toList();
    } else {
      return accounts.where((a) => a.isLiability).toList();
    }
  }

  Future<void> _loadTransactionsForAccount() async {
    if (_selectedAccount == null) return;

    setState(() {
      _isLoading = true;
    });

    final authProvider = context.read<AuthProvider>();
    final transactionsProvider = context.read<TransactionsProvider>();

    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken != null) {
      await transactionsProvider.fetchTransactions(
        accessToken: accessToken,
        accountId: _selectedAccount!.id,
        forceSync: false,
      );

      final transactions = transactionsProvider.transactions;
      _log.info('CalendarScreen', 'Loaded ${transactions.length} transactions for account ${_selectedAccount!.name}');

      if (transactions.isNotEmpty) {
        _log.debug('CalendarScreen', 'Sample transaction - name: ${transactions.first.name}, amount: ${transactions.first.amount}, nature: ${transactions.first.nature}');
      }

      // Store transactions for date filtering
      _transactions = List.from(transactions);

      _calculateDailyChanges(transactions);
      _log.info('CalendarScreen', 'Calculated ${_dailyChanges.length} days with changes');
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _calculateDailyChanges(List<Transaction> transactions) {
    final changes = <String, double>{};

    _log.debug('CalendarScreen', 'Starting to calculate daily changes for ${transactions.length} transactions');

    for (var transaction in transactions) {
      try {
        final date = DateTime.parse(transaction.date);
        final dateKey = DateFormat('yyyy-MM-dd').format(date);

        // Parse amount with proper sign handling
        String trimmedAmount = transaction.amount.trim();
        trimmedAmount = trimmedAmount.replaceAll('\u2212', '-'); // Normalize minus sign

        // Detect if the amount has a negative sign
        bool hasNegativeSign = trimmedAmount.startsWith('-') || trimmedAmount.endsWith('-');

        // Remove all non-numeric characters except decimal point and minus sign
        String numericString = trimmedAmount.replaceAll(RegExp(r'[^\d.\-]'), '');

        // Parse the numeric value
        double amount = double.tryParse(numericString.replaceAll('-', '')) ?? 0.0;

        // Apply the sign from the string
        if (hasNegativeSign) {
          amount = -amount;
        }

        // For asset accounts, flip the sign to match accounting conventions
        // For liability accounts, also flip the sign
        if (_selectedAccount?.isAsset == true || _selectedAccount?.isLiability == true) {
          amount = -amount;
        }

        _log.debug('CalendarScreen', 'Processing transaction ${transaction.name} - date: $dateKey, raw amount: ${transaction.amount}, parsed: $amount, isAsset: ${_selectedAccount?.isAsset}, isLiability: ${_selectedAccount?.isLiability}');

        changes[dateKey] = (changes[dateKey] ?? 0.0) + amount;
        _log.debug('CalendarScreen', 'Date $dateKey now has total: ${changes[dateKey]}');
      } catch (e) {
        _log.error('CalendarScreen', 'Failed to parse transaction date: ${transaction.date}, error: $e');
      }
    }

    _log.info('CalendarScreen', 'Final changes map has ${changes.length} entries');
    changes.forEach((date, amount) {
      _log.debug('CalendarScreen', '$date -> $amount');
    });

    setState(() {
      _dailyChanges = changes;
    });
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
      _selectedDate = null; // Clear selection when changing month
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
      _selectedDate = null; // Clear selection when changing month
    });
  }

  void _onDayCellTap(DateTime date) {
    if (_selectedDate != null &&
        _selectedDate!.year == date.year &&
        _selectedDate!.month == date.month &&
        _selectedDate!.day == date.day) {
      // Second tap on same date - show transactions dialog
      _showTransactionsDialog(date);
    } else {
      // First tap - select the date
      setState(() {
        _selectedDate = date;
      });
    }
  }

  List<Transaction> _getTransactionsForDate(DateTime date) {
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    return _transactions.where((transaction) {
      try {
        final transactionDate = DateTime.parse(transaction.date);
        final transactionDateKey = DateFormat('yyyy-MM-dd').format(transactionDate);
        return transactionDateKey == dateKey;
      } catch (e) {
        return false;
      }
    }).toList();
  }

  void _showTransactionsDialog(DateTime date) {
    final transactions = _getTransactionsForDate(date);
    final formattedDate = DateFormat('yyyy-MM-dd').format(date);
    final colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            formattedDate,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: transactions.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        'No transactions on this day',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: transactions.length,
                    itemBuilder: (context, index) {
                      final transaction = transactions[index];
                      return _buildTransactionTile(transaction);
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTransactionTile(Transaction transaction) {
    // Parse amount to determine if positive or negative
    String trimmedAmount = transaction.amount.trim();
    trimmedAmount = trimmedAmount.replaceAll('\u2212', '-');
    bool isNegative = trimmedAmount.startsWith('-') || trimmedAmount.endsWith('-');

    // For asset accounts, flip the sign interpretation
    if (_selectedAccount?.isAsset == true || _selectedAccount?.isLiability == true) {
      isNegative = !isNegative;
    }

    final isExpense = isNegative;
    final iconData = isExpense ? Icons.remove_circle : Icons.add_circle;
    final iconColor = isExpense ? Colors.red : Colors.green;
    final amountColor = isExpense ? Colors.red.shade700 : Colors.green.shade700;

    return ListTile(
      leading: Icon(
        iconData,
        color: iconColor,
        size: 28,
      ),
      title: Text(
        transaction.name,
        style: const TextStyle(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: transaction.notes != null && transaction.notes!.isNotEmpty
          ? Text(
              transaction.notes!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            )
          : null,
      trailing: Text(
        transaction.amount,
        style: TextStyle(
          color: amountColor,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  double _getTotalForMonth() {
    double total = 0.0;
    final yearMonth = DateFormat('yyyy-MM').format(_currentMonth);

    _dailyChanges.forEach((date, change) {
      if (date.startsWith(yearMonth)) {
        total += change;
      }
    });

    return total;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accountsProvider = context.watch<AccountsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Calendar'),
      ),
      body: Column(
        children: [
          // Account type selector
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account Type',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment<String>(
                      value: 'asset',
                      label: Text('Assets'),
                      icon: Icon(Icons.account_balance_wallet),
                    ),
                    ButtonSegment<String>(
                      value: 'liability',
                      label: Text('Liabilities'),
                      icon: Icon(Icons.credit_card),
                    ),
                  ],
                  selected: {_accountType},
                  onSelectionChanged: (Set<String> newSelection) {
                    setState(() {
                      _accountType = newSelection.first;
                      // Switch to first account of new type
                      final filteredAccounts = _getFilteredAccounts(accountsProvider.accounts);
                      _selectedAccount = filteredAccounts.isNotEmpty ? filteredAccounts.first : null;
                      _dailyChanges = {};
                      _transactions = [];
                      _selectedDate = null; // Clear selection when changing account type
                    });
                    if (_selectedAccount != null) {
                      _loadTransactionsForAccount();
                    }
                  },
                ),
              ],
            ),
          ),

          // Account selector
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: DropdownButtonFormField<Account>(
              value: _selectedAccount,
              decoration: InputDecoration(
                labelText: 'Select Account',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              items: _getFilteredAccounts(accountsProvider.accounts).map((account) {
                return DropdownMenuItem(
                  value: account,
                  child: Text('${account.name} (${account.currency})'),
                );
              }).toList(),
              onChanged: (Account? newAccount) {
                setState(() {
                  _selectedAccount = newAccount;
                  _dailyChanges = {};
                  _transactions = [];
                  _selectedDate = null; // Clear selection when changing account
                });
                _loadTransactionsForAccount();
              },
            ),
          ),

          // Month selector
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _previousMonth,
                ),
                Text(
                  DateFormat('yyyy-MM').format(_currentMonth),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _nextMonth,
                ),
              ],
            ),
          ),

          // Monthly total
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Monthly Change',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  _formatCurrency(_getTotalForMonth()),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: _getTotalForMonth() >= 0
                        ? Colors.green
                        : Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // Calendar
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildCalendar(colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendar(ColorScheme colorScheme) {
    final firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    final daysInMonth = lastDayOfMonth.day;
    final startWeekday = firstDayOfMonth.weekday % 7; // 0 = Sunday

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // Weekday headers
            SizedBox(
              height: 40,
              child: Row(
                children: ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((day) {
                  return Expanded(
                    child: Center(
                      child: Text(
                        day,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            // Calendar grid
            ...List.generate((daysInMonth + startWeekday + 6) ~/ 7, (weekIndex) {
              return SizedBox(
                height: 70,
                child: Row(
                  children: List.generate(7, (dayIndex) {
                    final dayNumber = weekIndex * 7 + dayIndex - startWeekday + 1;

                    if (dayNumber < 1 || dayNumber > daysInMonth) {
                      return const Expanded(child: SizedBox.shrink());
                    }

                    final date = DateTime(_currentMonth.year, _currentMonth.month, dayNumber);
                    final dateKey = DateFormat('yyyy-MM-dd').format(date);
                    final change = _dailyChanges[dateKey] ?? 0.0;
                    final hasChange = _dailyChanges.containsKey(dateKey);

                    return Expanded(
                      child: _buildDayCell(
                        date,
                        dayNumber,
                        change,
                        hasChange,
                        colorScheme,
                      ),
                    );
                  }).toList(),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildDayCell(DateTime date, int day, double change, bool hasChange, ColorScheme colorScheme) {
    Color? backgroundColor;
    Color? textColor;

    // Check if this date is selected
    final isSelected = _selectedDate != null &&
        _selectedDate!.year == date.year &&
        _selectedDate!.month == date.month &&
        _selectedDate!.day == date.day;

    if (hasChange) {
      if (change > 0) {
        backgroundColor = Colors.green.withValues(alpha: 0.2);
        textColor = Colors.green.shade700;
      } else if (change < 0) {
        backgroundColor = Colors.red.withValues(alpha: 0.2);
        textColor = Colors.red.shade700;
      }
    }

    return GestureDetector(
      onTap: () => _onDayCellTap(date),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: backgroundColor ?? colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Theme.of(context).primaryColor : colorScheme.outlineVariant,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                day.toString(),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
              if (hasChange) ...[
                const SizedBox(height: 2),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _formatAmount(change),
                      style: TextStyle(
                        fontSize: 10,
                        color: textColor,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatAmount(double amount) {
    // Support up to 8 decimal places, but omit unnecessary trailing zeros
    final formatter = NumberFormat('#,##0.########');
    final sign = amount >= 0 ? '+' : '';
    return '$sign${formatter.format(amount)}';
  }

  String _formatCurrency(double amount) {
    final currencySymbol = _selectedAccount?.currency ?? '';
    // Support up to 8 decimal places for monthly total
    final formatter = NumberFormat('#,##0.########');
    final sign = amount >= 0 ? '+' : '';
    return '$sign$currencySymbol${formatter.format(amount.abs())}';
  }
}
