import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/accounts_provider.dart';
import '../providers/transactions_provider.dart';
import '../providers/auth_provider.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  Account? _selectedAccount;
  DateTime _currentMonth = DateTime.now();
  Map<String, double> _dailyChanges = {};
  bool _isLoading = false;

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
      setState(() {
        _selectedAccount = accountsProvider.accounts.first;
      });
      await _loadTransactionsForAccount();
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
      debugPrint('Calendar: Loaded ${transactions.length} transactions for account ${_selectedAccount!.name}');

      if (transactions.isNotEmpty) {
        debugPrint('Calendar: Sample transaction - name: ${transactions.first.name}, amount: ${transactions.first.amount}, nature: ${transactions.first.nature}');
      }

      _calculateDailyChanges(transactions);
      debugPrint('Calendar: Calculated ${_dailyChanges.length} days with changes');
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _calculateDailyChanges(List<Transaction> transactions) {
    final changes = <String, double>{};

    debugPrint('Calendar: Starting to calculate daily changes for ${transactions.length} transactions');

    for (var transaction in transactions) {
      try {
        final date = DateTime.parse(transaction.date);
        final dateKey = DateFormat('yyyy-MM-dd').format(date);

        // Parse amount as absolute value first
        final cleanedAmount = transaction.amount.replaceAll(RegExp(r'[^\d.-]'), '');
        double amount = double.tryParse(cleanedAmount) ?? 0.0;

        debugPrint('Calendar: Processing transaction ${transaction.name} - date: $dateKey, raw amount: ${transaction.amount}, cleaned: $cleanedAmount, parsed: $amount, nature: ${transaction.nature}');

        // For expenses, make the amount negative
        // For income, keep it positive
        if (transaction.nature == 'expense') {
          amount = -amount.abs();
        } else {
          amount = amount.abs();
        }

        changes[dateKey] = (changes[dateKey] ?? 0.0) + amount;
        debugPrint('Calendar: Date $dateKey now has total: ${changes[dateKey]}');
      } catch (e) {
        debugPrint('Calendar: Failed to parse transaction date: ${transaction.date}, error: $e');
      }
    }

    debugPrint('Calendar: Final changes map has ${changes.length} entries');
    changes.forEach((date, amount) {
      debugPrint('Calendar: $date -> $amount');
    });

    setState(() {
      _dailyChanges = changes;
    });
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    });
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
        title: const Text('帳戶日曆'),
      ),
      body: Column(
        children: [
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
                labelText: '選擇帳戶',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              items: accountsProvider.accounts.map((account) {
                return DropdownMenuItem(
                  value: account,
                  child: Text('${account.name} (${account.currency})'),
                );
              }).toList(),
              onChanged: (Account? newAccount) {
                setState(() {
                  _selectedAccount = newAccount;
                  _dailyChanges = {};
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
                  '本月盈虧',
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
                children: ['日', '一', '二', '三', '四', '五', '六'].map((day) {
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

  Widget _buildDayCell(int day, double change, bool hasChange, ColorScheme colorScheme) {
    Color? backgroundColor;
    Color? textColor;

    if (hasChange) {
      if (change > 0) {
        backgroundColor = Colors.green.withValues(alpha: 0.2);
        textColor = Colors.green.shade700;
      } else if (change < 0) {
        backgroundColor = Colors.red.withValues(alpha: 0.2);
        textColor = Colors.red.shade700;
      }
    }

    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: backgroundColor ?? colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 1,
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
              Text(
                _formatAmount(change),
                style: TextStyle(
                  fontSize: 10,
                  color: textColor,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatAmount(double amount) {
    final formatter = NumberFormat('#,##0.##');
    final sign = amount >= 0 ? '+' : '';
    return '$sign${formatter.format(amount)}';
  }

  String _formatCurrency(double amount) {
    final currencySymbol = _selectedAccount?.currency ?? '';
    final formatter = NumberFormat('#,##0.00');
    final sign = amount >= 0 ? '+' : '';
    return '$sign$currencySymbol${formatter.format(amount.abs())}';
  }
}
