import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/account.dart';
import '../providers/auth_provider.dart';
import '../providers/accounts_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../widgets/account_card.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/currency_filter.dart';
import 'transaction_form_screen.dart';
import 'transactions_list_screen.dart';
import 'log_viewer_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  DashboardScreenState createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  final LogService _log = LogService.instance;
  bool _showSyncSuccess = false;
  int _previousPendingCount = 0;
  TransactionsProvider? _transactionsProvider;

  // Filter state
  AccountFilter _accountFilter = AccountFilter.all;
  Set<String> _selectedCurrencies = {};

  // Group by type state
  bool _groupByType = false;
  final Set<String> _collapsedGroups = {};

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadPreferences();

    // Listen for sync completion to show success indicator
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
      _previousPendingCount = _transactionsProvider?.pendingCount ?? 0;
      _transactionsProvider?.addListener(_onTransactionsChanged);
    });
  }

  @override
  void dispose() {
    _transactionsProvider?.removeListener(_onTransactionsChanged);
    super.dispose();
  }

  void _onTransactionsChanged() {
    final transactionsProvider = _transactionsProvider;
    if (transactionsProvider == null || !mounted) {
      return;
    }
    
    final currentPendingCount = transactionsProvider.pendingCount;

    // If pending count decreased, it means transactions were synced
    if (_previousPendingCount > 0 && currentPendingCount < _previousPendingCount) {
      setState(() {
        _showSyncSuccess = true;
      });

      // Hide the success indicator after 3 seconds
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _showSyncSuccess = false;
          });
        }
      });
    }

    _previousPendingCount = currentPendingCount;
  }

  Future<void> _loadAccounts() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final accountsProvider = Provider.of<AccountsProvider>(context, listen: false);
    
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      // Token is invalid, redirect to login
      await authProvider.logout();
      return;
    }

    await accountsProvider.fetchAccounts(accessToken: accessToken);
    
    // Check if unauthorized
    if (accountsProvider.errorMessage == 'unauthorized') {
      await authProvider.logout();
    }
  }

  Future<void> _loadPreferences() async {
    final groupByType = await PreferencesService.instance.getGroupByType();
    if (mounted) {
      setState(() {
        _groupByType = groupByType;
      });
    }
  }

  void reloadPreferences() {
    _loadPreferences();
  }

  Future<void> _handleRefresh() async {
    await _performManualSync();
  }

  Future<void> _performManualSync() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    // Show syncing indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Syncing data from server...'),
            ],
          ),
          duration: Duration(seconds: 30),
        ),
      );
    }

    try {
      // Perform full sync: upload pending, download from server, sync accounts
      await transactionsProvider.syncTransactions(accessToken: accessToken);

      // Reload accounts to show updated balances
      await _loadAccounts();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Sync completed successfully'),
              ],
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _log.error('DashboardScreen', 'Error in _performManualSync: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.error, color: Colors.white),
                SizedBox(width: 12),
                Expanded(child: Text('Sync failed. Please try again.')),
              ],
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String _formatAmount(String currency, double amount) {
    final symbol = _getCurrencySymbol(currency);
    final isSmallAmount = amount.abs() < 1 && amount != 0;
    final formattedAmount = amount.toStringAsFixed(isSmallAmount ? 4 : 0);

    // Split into integer and decimal parts
    final parts = formattedAmount.split('.');
    final integerPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );

    final finalAmount = parts.length > 1 ? '$integerPart.${parts[1]}' : integerPart;
    return '$symbol$finalAmount $currency';
  }

  Set<String> _getAllCurrencies(AccountsProvider accountsProvider) {
    final currencies = <String>{};
    for (var account in accountsProvider.accounts) {
      currencies.add(account.currency);
    }
    return currencies;
  }

  List<Account> _getFilteredAccounts(AccountsProvider accountsProvider) {
    var accounts = accountsProvider.accounts.toList();

    // Filter by account type
    switch (_accountFilter) {
      case AccountFilter.assets:
        accounts = accounts.where((a) => a.isAsset).toList();
        break;
      case AccountFilter.liabilities:
        accounts = accounts.where((a) => a.isLiability).toList();
        break;
      case AccountFilter.all:
        // Show all accounts (assets and liabilities)
        accounts = accounts.where((a) => a.isAsset || a.isLiability).toList();
        break;
    }

    // Filter by currency if any selected
    if (_selectedCurrencies.isNotEmpty) {
      accounts = accounts.where((a) => _selectedCurrencies.contains(a.currency)).toList();
    }

    return accounts;
  }

  String _getCurrencySymbol(String currency) {
    switch (currency.toUpperCase()) {
      case 'USD':
        return '\$';
      case 'TWD':
        return '\$';
      case 'BTC':
        return '₿';
      case 'ETH':
        return 'Ξ';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      case 'JPY':
        return '¥';
      case 'CNY':
        return '¥';
      default:
        return ' ';
    }
  }

  Future<void> _handleAccountTap(Account account) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TransactionFormScreen(account: account),
    );

    // Refresh accounts if transaction was created successfully
    if (result == true && mounted) {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Refreshing accounts...'),
            ],
          ),
          duration: Duration(seconds: 2),
        ),
      );

      // Small delay to ensure smooth UI transition
      await Future.delayed(const Duration(milliseconds: 50));

      // Refresh the accounts
      await _loadAccounts();

      // Hide loading snackbar and show success
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Accounts updated'),
              ],
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _handleAccountSwipe(Account account) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TransactionsListScreen(account: account),
      ),
    );

    // Refresh accounts when returning from transaction list
    if (mounted) {
      await _loadAccounts();
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accountsProvider = Provider.of<AccountsProvider>(context, listen: false);

      accountsProvider.clearAccounts();
      await authProvider.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (_showSyncSuccess)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AnimatedOpacity(
                opacity: _showSyncSuccess ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: const Icon(
                  Icons.cloud_done,
                  color: Colors.green,
                  size: 28,
                ),
              ),
            ),
          Semantics(
            label: 'Open debug logs',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.bug_report),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LogViewerScreen()),
                );
              },
              tooltip: 'Debug Logs',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _handleRefresh,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
            tooltip: 'Sign Out',
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectivityBanner(),
          Expanded(
            child: Consumer2<AuthProvider, AccountsProvider>(
              builder: (context, authProvider, accountsProvider, _) {
                // Show loading state during initialization or when loading
                if (accountsProvider.isInitializing || accountsProvider.isLoading) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

          // Show error state
          if (accountsProvider.errorMessage != null && 
              accountsProvider.errorMessage != 'unauthorized') {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load accounts',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      accountsProvider.errorMessage!,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _handleRefresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            );
          }

          // Show empty state
          if (accountsProvider.accounts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      size: 64,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No accounts yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add accounts in the web app to see them here.',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _handleRefresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
              ),
            );
          }

          // Show accounts list
          return RefreshIndicator(
            onRefresh: _handleRefresh,
            child: CustomScrollView(
              slivers: [
                // Net Worth Card with Asset/Liability filter
                SliverToBoxAdapter(
                  child: NetWorthCard(
                    assetTotalsByCurrency: accountsProvider.assetTotalsByCurrency,
                    liabilityTotalsByCurrency: accountsProvider.liabilityTotalsByCurrency,
                    currentFilter: _accountFilter,
                    onFilterChanged: (filter) {
                      setState(() {
                        _accountFilter = filter;
                      });
                    },
                    formatAmount: _formatAmount,
                  ),
                ),

                // Currency filter
                SliverToBoxAdapter(
                  child: CurrencyFilter(
                    availableCurrencies: _getAllCurrencies(accountsProvider),
                    selectedCurrencies: _selectedCurrencies,
                    onSelectionChanged: (currencies) {
                      setState(() {
                        _selectedCurrencies = currencies;
                      });
                    },
                  ),
                ),

                // Spacing
                const SliverToBoxAdapter(
                  child: SizedBox(height: 8),
                ),

                // Filtered accounts section
                ..._buildFilteredAccountsSection(accountsProvider),

                // Bottom padding
                const SliverToBoxAdapter(
                  child: SizedBox(height: 24),
                ),
              ],
            ),
          );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFilteredAccountsSection(AccountsProvider accountsProvider) {
    final filteredAccounts = _getFilteredAccounts(accountsProvider);

    if (filteredAccounts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No accounts match the current filter',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    // Sort accounts: by type, then currency, then balance
    filteredAccounts.sort((a, b) {
      if (a.isAsset && !b.isAsset) return -1;
      if (!a.isAsset && b.isAsset) return 1;
      int typeComparison = a.accountType.compareTo(b.accountType);
      if (typeComparison != 0) return typeComparison;
      int currencyComparison = a.currency.compareTo(b.currency);
      if (currencyComparison != 0) return currencyComparison;
      return b.balanceAsDouble.compareTo(a.balanceAsDouble);
    });

    if (_groupByType) {
      return _buildGroupedAccountsList(filteredAccounts);
    }

    return _buildFlatAccountsList(filteredAccounts);
  }

  List<Widget> _buildFlatAccountsList(List<Account> accounts) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final account = accounts[index];
              return AccountCard(
                account: account,
                onTap: () => _handleAccountTap(account),
                onSwipe: () => _handleAccountSwipe(account),
              );
            },
            childCount: accounts.length,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildGroupedAccountsList(List<Account> accounts) {
    // Group accounts by accountType
    final groups = <String, List<Account>>{};
    for (final account in accounts) {
      groups.putIfAbsent(account.accountType, () => []).add(account);
    }

    final slivers = <Widget>[];
    for (final entry in groups.entries) {
      final accountType = entry.key;
      final groupAccounts = entry.value;
      final isCollapsed = _collapsedGroups.contains(accountType);

      // Use first account to get display name and icon
      final displayName = groupAccounts.first.displayAccountType;

      slivers.add(
        SliverToBoxAdapter(
          child: _CollapsibleTypeHeader(
            title: displayName,
            count: groupAccounts.length,
            accountType: accountType,
            isCollapsed: isCollapsed,
            onToggle: () {
              setState(() {
                if (isCollapsed) {
                  _collapsedGroups.remove(accountType);
                } else {
                  _collapsedGroups.add(accountType);
                }
              });
            },
          ),
        ),
      );

      if (!isCollapsed) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final account = groupAccounts[index];
                  return AccountCard(
                    account: account,
                    onTap: () => _handleAccountTap(account),
                    onSwipe: () => _handleAccountSwipe(account),
                  );
                },
                childCount: groupAccounts.length,
              ),
            ),
          ),
        );
      }
    }

    return slivers;
  }
}

class _CollapsibleTypeHeader extends StatelessWidget {
  final String title;
  final int count;
  final String accountType;
  final bool isCollapsed;
  final VoidCallback onToggle;

  const _CollapsibleTypeHeader({
    required this.title,
    required this.count,
    required this.accountType,
    required this.isCollapsed,
    required this.onToggle,
  });

  IconData _getTypeIcon() {
    switch (accountType) {
      case 'depository':
        return Icons.account_balance;
      case 'credit_card':
        return Icons.credit_card;
      case 'investment':
        return Icons.trending_up;
      case 'loan':
        return Icons.receipt_long;
      case 'property':
        return Icons.home;
      case 'vehicle':
        return Icons.directions_car;
      case 'crypto':
        return Icons.currency_bitcoin;
      case 'other_asset':
        return Icons.category;
      case 'other_liability':
        return Icons.payment;
      default:
        return Icons.account_balance_wallet;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          children: [
            Icon(
              _getTypeIcon(),
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            const Spacer(),
            Icon(
              isCollapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
