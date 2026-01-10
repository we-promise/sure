import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/account.dart';
import '../services/accounts_service.dart';
import '../services/offline_storage_service.dart';
import '../services/connectivity_service.dart';
import '../services/log_service.dart';

class AccountsProvider with ChangeNotifier {
  final AccountsService _accountsService = AccountsService();
  final OfflineStorageService _offlineStorage = OfflineStorageService();
  final LogService _log = LogService.instance;

  List<Account> _accounts = [];
  bool _isLoading = false;
  bool _isInitializing = true;
  String? _errorMessage;
  Map<String, dynamic>? _pagination;
  ConnectivityService? _connectivityService;

  List<Account> get accounts => _accounts;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing;
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

  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
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

  /// Fetch accounts (offline-first approach)
  Future<bool> fetchAccounts({
    required String accessToken,
    int page = 1,
    int perPage = 25,
    bool forceSync = false,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // Always load from local storage first for instant display
      final cachedAccounts = await _offlineStorage.getAccounts();
      if (cachedAccounts.isNotEmpty) {
        _accounts = cachedAccounts;
        _isInitializing = false;
        notifyListeners();
      }

      // If online and (force sync or no cached data), fetch from server
      final isOnline = _connectivityService?.isOnline ?? false;
      if (isOnline && (forceSync || cachedAccounts.isEmpty)) {
        final result = await _accountsService.getAccounts(
          accessToken: accessToken,
          page: page,
          perPage: perPage,
        );

        if (result['success'] == true && result.containsKey('accounts')) {
          final serverAccounts = (result['accounts'] as List<dynamic>?)?.cast<Account>() ?? [];
          _pagination = result['pagination'] as Map<String, dynamic>?;

          // Save to local cache
          await _offlineStorage.clearAccounts();
          await _offlineStorage.saveAccounts(serverAccounts);

          // Update in-memory accounts
          _accounts = serverAccounts;
          _errorMessage = null;
        } else {
          // If server fetch failed but we have cached data, that's OK
          if (_accounts.isEmpty) {
            _errorMessage = result['error'] as String? ?? 'Failed to fetch accounts';
          }
        }
      } else if (!isOnline && _accounts.isEmpty) {
        _errorMessage = 'You are offline. Please connect to the internet to load accounts.';
      }

      _isLoading = false;
      _isInitializing = false;
      notifyListeners();
      return _accounts.isNotEmpty;
    } catch (e) {
      _log.error('AccountsProvider', 'Error in fetchAccounts: $e');
      // If we have cached accounts, show them even if sync fails
      if (_accounts.isEmpty) {
        // Provide more specific error messages based on exception type
        if (e is SocketException) {
          _errorMessage = 'Network error. Please check your internet connection and try again.';
          _log.error('AccountsProvider', 'SocketException: $e');
        } else if (e is TimeoutException) {
          _errorMessage = 'Request timed out. Please check your connection and try again.';
          _log.error('AccountsProvider', 'TimeoutException: $e');
        } else if (e is FormatException) {
          _errorMessage = 'Server response error. Please try again later.';
          _log.error('AccountsProvider', 'FormatException: $e');
        } else if (e.toString().contains('401') || e.toString().contains('unauthorized')) {
          _errorMessage = 'unauthorized';
          _log.error('AccountsProvider', 'Unauthorized error: $e');
        } else if (e.toString().contains('HandshakeException') ||
                   e.toString().contains('certificate') ||
                   e.toString().contains('SSL')) {
          _errorMessage = 'Secure connection error. Please check your internet connection and try again.';
          _log.error('AccountsProvider', 'SSL/Certificate error: $e');
        } else {
          _errorMessage = 'Something went wrong. Please try again.';
          _log.error('AccountsProvider', 'Unhandled exception: $e');
        }
      }
      _isLoading = false;
      _isInitializing = false;
      notifyListeners();
      return _accounts.isNotEmpty;
    }
  }

  void clearAccounts() {
    _accounts = [];
    _pagination = null;
    _errorMessage = null;
    _isInitializing = true;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
