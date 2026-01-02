import 'package:flutter/foundation.dart';
import '../models/account.dart';
import '../services/accounts_service.dart';

class AccountsProvider with ChangeNotifier {
  final AccountsService _accountsService = AccountsService();

  List<Account> _accounts = [];
  bool _isLoading = false;
  bool _isInitializing = true; // Track if we've fetched accounts at least once
  String? _errorMessage;
  Map<String, dynamic>? _pagination;

  List<Account> get accounts => _accounts;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing; // Expose initialization state
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get pagination => _pagination;

  List<Account> get assetAccounts {
    final assets = _accounts.where((a) => a.isAsset).toList();
    _sortAccounts(assets);
    return assets;
  }

  List<Account> get liabilityAccounts {
    final liabilities = _accounts.where((a) => a.isLiability).toList();
    _sortAccounts(liabilities);
    return liabilities;
  }

  Map<String, double> get assetTotalsByCurrency {
    final totals = <String, double>{};
    for (var account in _accounts.where((a) => a.isAsset)) {
      totals[account.currency] = (totals[account.currency] ?? 0.0) + account.balanceAsDouble;
    }
    return totals;
  }

  Map<String, double> get liabilityTotalsByCurrency {
    final totals = <String, double>{};
    for (var account in _accounts.where((a) => a.isLiability)) {
      totals[account.currency] = (totals[account.currency] ?? 0.0) + account.balanceAsDouble;
    }
    return totals;
  }

  void _sortAccounts(List<Account> accounts) {
    accounts.sort((a, b) {
      // 1. Sort by account type
      int typeComparison = a.accountType.compareTo(b.accountType);
      if (typeComparison != 0) return typeComparison;

      // 2. Sort by currency
      int currencyComparison = a.currency.compareTo(b.currency);
      if (currencyComparison != 0) return currencyComparison;

      // 3. Sort by balance (descending - highest first)
      int balanceComparison = b.balanceAsDouble.compareTo(a.balanceAsDouble);
      if (balanceComparison != 0) return balanceComparison;

      // 4. Sort by name
      return a.name.compareTo(b.name);
    });
  }

  Future<bool> fetchAccounts({
    required String accessToken,
    int page = 1,
    int perPage = 25,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _accountsService.getAccounts(
        accessToken: accessToken,
        page: page,
        perPage: perPage,
      );

      if (result['success'] == true && result.containsKey('accounts')) {
        _accounts = (result['accounts'] as List<dynamic>?)?.cast<Account>() ?? [];
        _pagination = result['pagination'] as Map<String, dynamic>?;
        _isLoading = false;
        _isInitializing = false; // Mark as initialized after first fetch
        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] as String? ?? 'Failed to fetch accounts';
        _isLoading = false;
        _isInitializing = false; // Mark as initialized even on error
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Connection error. Please check your internet connection.';
      _isLoading = false;
      _isInitializing = false; // Mark as initialized even on error
      notifyListeners();
      return false;
    }
  }

  void clearAccounts() {
    _accounts = [];
    _pagination = null;
    _errorMessage = null;
    _isInitializing = true; // Reset initialization state on clear
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
