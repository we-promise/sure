import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../models/transaction.dart';
import '../models/offline_transaction.dart';
import '../services/transactions_service.dart';
import '../services/offline_storage_service.dart';
import '../services/sync_service.dart';
import '../services/connectivity_service.dart';
import '../services/log_service.dart';

class TransactionsProvider with ChangeNotifier {
  final TransactionsService _transactionsService = TransactionsService();
  final OfflineStorageService _offlineStorage = OfflineStorageService();
  final SyncService _syncService = SyncService();
  final LogService _log = LogService.instance;

  List<OfflineTransaction> _transactions = [];
  bool _isLoading = false;
  String? _error;
  ConnectivityService? _connectivityService;
  String? _lastAccessToken;
  bool _isAutoSyncing = false;

  List<Transaction> get transactions =>
      UnmodifiableListView(_transactions.map((t) => t.toTransaction()));

  List<OfflineTransaction> get offlineTransactions =>
      UnmodifiableListView(_transactions);

  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasPendingTransactions =>
      _transactions.any((t) => t.syncStatus == SyncStatus.pending);
  int get pendingCount =>
      _transactions.where((t) => t.syncStatus == SyncStatus.pending).length;

  SyncService get syncService => _syncService;

  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
    _connectivityService?.addListener(_onConnectivityChanged);
  }

  void _onConnectivityChanged() async {
    // Auto-sync when connectivity is restored
    if (_connectivityService?.isOnline == true &&
        hasPendingTransactions &&
        _lastAccessToken != null &&
        !_isAutoSyncing) {
      _log.info('TransactionsProvider', 'Connectivity restored, auto-syncing $pendingCount pending transactions');
      _isAutoSyncing = true;

      try {
        await syncTransactions(accessToken: _lastAccessToken!);
        _log.info('TransactionsProvider', 'Auto-sync completed successfully');
      } catch (e) {
        _log.error('TransactionsProvider', 'Auto-sync failed: $e');
      } finally {
        _isAutoSyncing = false;
      }
    }
  }

  /// Fetch transactions (offline-first approach)
  Future<void> fetchTransactions({
    required String accessToken,
    String? accountId,
    bool forceSync = false,
  }) async {
    _lastAccessToken = accessToken; // Store for auto-sync
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Always load from local storage first
      final localTransactions = await _offlineStorage.getTransactions(
        accountId: accountId,
      );

      debugPrint('[TransactionsProvider] Loaded ${localTransactions.length} transactions from local storage (accountId: $accountId)');

      _transactions = localTransactions;
      notifyListeners();

      // If online and force sync, or if local storage is empty, sync from server
      final isOnline = _connectivityService?.isOnline ?? true;
      debugPrint('[TransactionsProvider] Online: $isOnline, ForceSync: $forceSync, LocalEmpty: ${localTransactions.isEmpty}');

      if (isOnline && (forceSync || localTransactions.isEmpty)) {
        debugPrint('[TransactionsProvider] Syncing from server for accountId: $accountId');
        final result = await _syncService.syncFromServer(
          accessToken: accessToken,
          accountId: accountId,
        );

        if (result.success) {
          debugPrint('[TransactionsProvider] Sync successful, synced ${result.syncedCount} transactions');
          // Reload from local storage after sync
          final updatedTransactions = await _offlineStorage.getTransactions(
            accountId: accountId,
          );
          debugPrint('[TransactionsProvider] After sync, loaded ${updatedTransactions.length} transactions from local storage');
          _transactions = updatedTransactions;
          _error = null;
        } else {
          debugPrint('[TransactionsProvider] Sync failed: ${result.error}');
          _error = result.error;
        }
      }
    } catch (e) {
      debugPrint('[TransactionsProvider] Error in fetchTransactions: $e');
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Create a new transaction (offline-first)
  Future<bool> createTransaction({
    required String accessToken,
    required String accountId,
    required String name,
    required String date,
    required String amount,
    required String currency,
    required String nature,
    String? notes,
  }) async {
    _lastAccessToken = accessToken; // Store for auto-sync

    try {
      final isOnline = _connectivityService?.isOnline ?? false;

      if (isOnline) {
        // Try to create on server first
        final result = await _transactionsService.createTransaction(
          accessToken: accessToken,
          accountId: accountId,
          name: name,
          date: date,
          amount: amount,
          currency: currency,
          nature: nature,
          notes: notes,
        );

        if (result['success'] == true) {
          // Save to local storage as synced
          final serverTransaction = result['transaction'] as Transaction;
          await _offlineStorage.saveTransaction(
            accountId: accountId,
            name: name,
            date: date,
            amount: amount,
            currency: currency,
            nature: nature,
            notes: notes,
            serverId: serverTransaction.id,
            syncStatus: SyncStatus.synced,
          );

          // Reload transactions
          await fetchTransactions(accessToken: accessToken);
          return true;
        } else {
          // If server creation fails but we're online, save locally as pending
          await _offlineStorage.saveTransaction(
            accountId: accountId,
            name: name,
            date: date,
            amount: amount,
            currency: currency,
            nature: nature,
            notes: notes,
            syncStatus: SyncStatus.pending,
          );

          _error = result['error'] as String? ?? 'Failed to create transaction';
          await fetchTransactions(accessToken: accessToken);
          return false;
        }
      } else {
        // Offline - save locally as pending
        await _offlineStorage.saveTransaction(
          accountId: accountId,
          name: name,
          date: date,
          amount: amount,
          currency: currency,
          nature: nature,
          notes: notes,
          syncStatus: SyncStatus.pending,
        );

        // Reload transactions
        await fetchTransactions(accessToken: accessToken);
        return true; // Return true because it was saved locally
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Delete a transaction
  Future<bool> deleteTransaction({
    required String accessToken,
    required String transactionId,
  }) async {
    try {
      final isOnline = _connectivityService?.isOnline ?? false;

      if (isOnline) {
        // Try to delete on server
        final result = await _transactionsService.deleteTransaction(
          accessToken: accessToken,
          transactionId: transactionId,
        );

        if (result['success'] == true) {
          // Delete from local storage
          await _offlineStorage.deleteTransactionByServerId(transactionId);
          _transactions.removeWhere((t) => t.id == transactionId);
          notifyListeners();
          return true;
        } else {
          _error = result['error'] as String? ?? 'Failed to delete transaction';
          notifyListeners();
          return false;
        }
      } else {
        // Offline - just delete locally
        await _offlineStorage.deleteTransactionByServerId(transactionId);
        _transactions.removeWhere((t) => t.id == transactionId);
        notifyListeners();
        return true;
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Delete multiple transactions
  Future<bool> deleteMultipleTransactions({
    required String accessToken,
    required List<String> transactionIds,
  }) async {
    try {
      final isOnline = _connectivityService?.isOnline ?? false;

      if (isOnline) {
        final result = await _transactionsService.deleteMultipleTransactions(
          accessToken: accessToken,
          transactionIds: transactionIds,
        );

        if (result['success'] == true) {
          // Delete from local storage
          for (final id in transactionIds) {
            await _offlineStorage.deleteTransactionByServerId(id);
          }
          _transactions.removeWhere((t) => transactionIds.contains(t.id));
          notifyListeners();
          return true;
        } else {
          _error = result['error'] as String? ?? 'Failed to delete transactions';
          notifyListeners();
          return false;
        }
      } else {
        // Offline - just delete locally
        for (final id in transactionIds) {
          await _offlineStorage.deleteTransactionByServerId(id);
        }
        _transactions.removeWhere((t) => transactionIds.contains(t.id));
        notifyListeners();
        return true;
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Manually trigger sync
  Future<void> syncTransactions({
    required String accessToken,
  }) async {
    if (_connectivityService?.isOffline == true) {
      _error = 'Cannot sync while offline';
      notifyListeners();
      return;
    }

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _syncService.performFullSync(accessToken);

      if (result.success) {
        // Reload from local storage
        final updatedTransactions = await _offlineStorage.getTransactions();
        _transactions = updatedTransactions;
        _error = null;
      } else {
        _error = result.error;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearTransactions() {
    _transactions = [];
    _error = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectivityService?.removeListener(_onConnectivityChanged);
    super.dispose();
  }
}
