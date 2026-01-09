import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/account.dart';
import '../providers/auth_provider.dart';
import '../providers/accounts_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/log_service.dart';
import '../widgets/account_card.dart';
import '../widgets/connectivity_banner.dart';
import 'transaction_form_screen.dart';
import 'transactions_list_screen.dart';
import 'log_viewer_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final LogService _log = LogService.instance;
  bool _assetsExpanded = true;
  bool _liabilitiesExpanded = true;
  bool _showSyncSuccess = false;
  int _previousPendingCount = 0;
  TransactionsProvider? _transactionsProvider;

  @override
  void initState() {
    super.initState();
    _loadAccounts();

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

  List<String> _formatCurrencyItem(String currency, double amount) {
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
    return [currency, '$symbol$finalAmount'];
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
        title: const Text('Dashboard'),
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
                // Welcome header
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome${authProvider.user != null ? ', ${authProvider.user!.displayName}' : ''}',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Here\'s your financial overview',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),

                // Summary cards
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        if (accountsProvider.assetAccounts.isNotEmpty)
                          _SummaryCard(
                            title: 'Assets Total',
                            totals: accountsProvider.assetTotalsByCurrency,
                            color: Colors.green,
                            formatCurrencyItem: _formatCurrencyItem,
                          ),
                        if (accountsProvider.liabilityAccounts.isNotEmpty)
                          _SummaryCard(
                            title: 'Liabilities Total',
                            totals: accountsProvider.liabilityTotalsByCurrency,
                            color: Colors.red,
                            formatCurrencyItem: _formatCurrencyItem,
                          ),
                      ],
                    ),
                  ),
                ),

                // Assets section
                if (accountsProvider.assetAccounts.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _CollapsibleSectionHeader(
                      title: 'Assets',
                      count: accountsProvider.assetAccounts.length,
                      color: Colors.green,
                      isExpanded: _assetsExpanded,
                      onToggle: () {
                        setState(() {
                          _assetsExpanded = !_assetsExpanded;
                        });
                      },
                    ),
                  ),
                  if (_assetsExpanded)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final account = accountsProvider.assetAccounts[index];
                            return AccountCard(
                              account: account,
                              onTap: () => _handleAccountTap(account),
                              onSwipe: () => _handleAccountSwipe(account),
                            );
                          },
                          childCount: accountsProvider.assetAccounts.length,
                        ),
                      ),
                    ),
                ],

                // Liabilities section
                if (accountsProvider.liabilityAccounts.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _CollapsibleSectionHeader(
                      title: 'Liabilities',
                      count: accountsProvider.liabilityAccounts.length,
                      color: Colors.red,
                      isExpanded: _liabilitiesExpanded,
                      onToggle: () {
                        setState(() {
                          _liabilitiesExpanded = !_liabilitiesExpanded;
                        });
                      },
                    ),
                  ),
                  if (_liabilitiesExpanded)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final account = accountsProvider.liabilityAccounts[index];
                            return AccountCard(
                              account: account,
                              onTap: () => _handleAccountTap(account),
                              onSwipe: () => _handleAccountSwipe(account),
                            );
                          },
                          childCount: accountsProvider.liabilityAccounts.length,
                        ),
                      ),
                    ),
                ],

                // Uncategorized accounts
                ..._buildUncategorizedSection(accountsProvider),

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

  List<Widget> _buildUncategorizedSection(AccountsProvider accountsProvider) {
    final uncategorized = accountsProvider.accounts
        .where((a) => !a.isAsset && !a.isLiability)
        .toList();

    if (uncategorized.isEmpty) {
      return [];
    }

    return [
      SliverToBoxAdapter(
        child: _SimpleSectionHeader(
          title: 'Other Accounts',
          count: uncategorized.length,
          color: Colors.grey,
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final account = uncategorized[index];
              return AccountCard(
                account: account,
                onTap: () => _handleAccountTap(account),
                onSwipe: () => _handleAccountSwipe(account),
              );
            },
            childCount: uncategorized.length,
          ),
        ),
      ),
    ];
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final Map<String, double> totals;
  final Color color;
  final List<String> Function(String currency, double amount) formatCurrencyItem;

  const _SummaryCard({
    required this.title,
    required this.totals,
    required this.color,
    required this.formatCurrencyItem,
  });

  @override
  Widget build(BuildContext context) {
    final entries = totals.entries.toList();
    final rows = <Widget>[];

    // Group currencies into pairs (2 per row)
    for (int i = 0; i < entries.length; i += 2) {
      final first = entries[i];
      final firstFormatted = formatCurrencyItem(first.key, first.value);

      if (i + 1 < entries.length) {
        // Two items in this row
        final second = entries[i + 1];
        final secondFormatted = formatCurrencyItem(second.key, second.value);

        rows.add(
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      firstFormatted[0],
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      firstFormatted[1],
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                ' | ',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w300,
                  color: color.withValues(alpha: 0.5),
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      secondFormatted[0],
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      secondFormatted[1],
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      } else {
        // Only one item in this row
        rows.add(
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                firstFormatted[0],
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                firstFormatted[1],
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      }

      if (i + 2 < entries.length) {
        rows.add(const SizedBox(height: 4));
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(height: 8),
                ...rows,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _CollapsibleSectionHeader({
    required this.title,
    required this.count,
    required this.color,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const Spacer(),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              color: color,
            ),
          ],
        ),
      ),
    );
  }
}

class _SimpleSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;

  const _SimpleSectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              count.toString(),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
