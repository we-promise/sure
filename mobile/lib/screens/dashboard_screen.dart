import 'dart:async';
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
import '../widgets/sure_button.dart';
import '../widgets/sure_icon.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../theme/sure_typography.dart';
import 'transaction_form_screen.dart';
import 'transactions_list_screen.dart';
import '../l10n/app_localizations.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  DashboardScreenState createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  final LogService _log = LogService.instance;
  bool _showSyncSuccess = false;
  int _previousPendingCount = 0;
  Timer? _syncSuccessTimer;
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
    _syncSuccessTimer?.cancel();
    _transactionsProvider?.removeListener(_onTransactionsChanged);
    super.dispose();
  }

  void _onTransactionsChanged() {
    final transactionsProvider = _transactionsProvider;
    if (transactionsProvider == null || !mounted) {
      return;
    }

    final currentPendingCount = transactionsProvider.pendingCount;

    // Show sync success when pending count decreased (local transactions uploaded)
    if (_previousPendingCount > 0 && currentPendingCount < _previousPendingCount) {
      _showSyncSuccessIndicator();
    }

    _previousPendingCount = currentPendingCount;
  }

  void _showSyncSuccessIndicator() {
    _syncSuccessTimer?.cancel();

    setState(() {
      _showSyncSuccess = true;
    });

    _syncSuccessTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showSyncSuccess = false;
        });
      }
    });
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
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    // Show syncing indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(l.dashboardSyncing)),
            ],
          ),
          duration: const Duration(seconds: 30),
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
        if (transactionsProvider.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  SureIcon(SureIcons.circleAlert, color: palette.textInverse),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.dashboardSyncFailed,
                      style: TextStyle(color: palette.textInverse),
                    ),
                  ),
                ],
              ),
              backgroundColor: palette.destructive,
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          _showSyncSuccessIndicator();
        }
      }
    } catch (e) {
      _log.error('DashboardScreen', 'Error in _performManualSync: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                SureIcon(SureIcons.circleAlert, color: palette.textInverse),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l.dashboardSyncError,
                    style: TextStyle(color: palette.textInverse),
                  ),
                ),
              ],
            ),
            backgroundColor: palette.destructive,
            duration: const Duration(seconds: 3),
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
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
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
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(l.dashboardRefreshing)),
            ],
          ),
          duration: const Duration(seconds: 2),
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
          SnackBar(
            content: Row(
              children: [
                SureIcon(SureIcons.circleCheck, color: palette.textInverse),
                const SizedBox(width: 12),
                Text(
                  l.dashboardAccountsUpdated,
                  style: TextStyle(color: palette.textInverse),
                ),
              ],
            ),
            backgroundColor: palette.success,
            duration: const Duration(seconds: 1),
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;

    return Scaffold(
      body: Column(
        children: [
          const ConnectivityBanner(),
          if (_showSyncSuccess)
            AnimatedOpacity(
              opacity: _showSyncSuccess ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: SureSpacing.xl, vertical: SureSpacing.sm),
                color: palette.success.withValues(alpha: 0.1),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SureIcon(
                      SureIcons.cloudCheck,
                      color: palette.success,
                      size: 18,
                    ),
                    const SizedBox(width: SureSpacing.md),
                    Text(
                      l.dashboardSynced,
                      style: TextStyle(
                          color: palette.success, fontSize: SureTypography.sm),
                    ),
                  ],
                ),
              ),
            ),
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
                    SureIcon(
                      SureIcons.circleAlert,
                      size: 64,
                      color: palette.destructive,
                    ),
                    const SizedBox(height: SureSpacing.xl),
                    Text(
                      l.dashboardErrorLoadingAccounts,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: SureSpacing.md),
                    Text(
                      accountsProvider.errorMessage!,
                      style: TextStyle(color: palette.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: SureSpacing.xxxl),
                    SureButton(
                      label: l.commonTryAgain,
                      onPressed: _handleRefresh,
                      leading: const SureIcon(SureIcons.refresh, size: 18),
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
                    SureIcon(
                      SureIcons.wallet,
                      size: 64,
                      color: palette.textSubdued,
                    ),
                    const SizedBox(height: SureSpacing.xl),
                    Text(
                      l.dashboardNoAccounts,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: SureSpacing.md),
                    Text(
                      l.dashboardNoAccountsSubtitle,
                      style: TextStyle(color: palette.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: SureSpacing.xxxl),
                    SureButton(
                      label: l.commonRefresh,
                      onPressed: _handleRefresh,
                      leading: const SureIcon(SureIcons.refresh, size: 18),
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
                    netWorthFormatted: accountsProvider.netWorthFormatted,
                    isStale: accountsProvider.isBalanceSheetStale,
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
    final l = AppLocalizations.of(context);

    final palette = SureColors.of(context).palette;

    if (filteredAccounts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(SureSpacing.huge),
              child: Column(
                children: [
                  SureIcon(
                    SureIcons.wallet,
                    size: 48,
                    color: palette.textSubdued,
                  ),
                  const SizedBox(height: SureSpacing.xl),
                  Text(
                    l.dashboardFilterEmpty,
                    style: TextStyle(
                      color: palette.textSecondary,
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

  String _getTypeIconName() {
    switch (accountType) {
      case 'depository':
        return SureIcons.landmark;
      case 'credit_card':
        return SureIcons.creditCard;
      case 'investment':
        return SureIcons.trendingUp;
      case 'loan':
        return SureIcons.receipt;
      case 'property':
        return SureIcons.house;
      case 'vehicle':
        return SureIcons.car;
      case 'crypto':
        return SureIcons.bitcoin;
      case 'other_asset':
        return SureIcons.shapes;
      case 'other_liability':
        return SureIcons.handCoins;
      default:
        return SureIcons.wallet;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            SureSpacing.xl, SureSpacing.xl, SureSpacing.xl, SureSpacing.md),
        child: Row(
          children: [
            SureIcon(
              _getTypeIconName(),
              size: 18,
              color: palette.textSubdued,
            ),
            const SizedBox(width: SureSpacing.lg),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: SureTokens.weightMedium,
                  ),
            ),
            const SizedBox(width: SureSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: palette.surfaceInset,
                borderRadius: BorderRadius.circular(SureTokens.radiusLg),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: palette.textSecondary,
                  fontWeight: SureTokens.weightMedium,
                  fontSize: SureTypography.xs,
                ),
              ),
            ),
            const Spacer(),
            SureIcon(
              isCollapsed ? SureIcons.chevronDown : SureIcons.chevronUp,
              size: SureIconSize.md,
              color: palette.textSubdued,
            ),
          ],
        ),
      ),
    );
  }
}
