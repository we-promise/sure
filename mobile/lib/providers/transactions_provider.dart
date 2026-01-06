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
  bool _isListenerAttached = false;

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
    if (!_isListenerAttached) {
      _connectivityService?.addListener(_onConnectivityChanged);
      _isListenerAttached = true;
    }
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    
    // Auto-sync when connectivity is restored
    if (_connectivityService?.isOnline == true &&
        hasPendingTransactions &&
        _lastAccessToken != null &&
        !_isAutoSyncing) {
      _log.info('TransactionsProvider', 'Connectivity restored, auto-syncing $pendingCount pending transactions');
      _isAutoSyncing = true;

      syncTransactions(accessToken: _lastAccessToken!).then((_) {
        if (mounted) {
          _log.info('TransactionsProvider', 'Auto-sync completed successfully');
        }
      }).catchError((e) {
        if (mounted) {
          _log.error('TransactionsProvider', 'Auto-sync failed: $e');
        }
      }).whenComplete(() {
        if (mounted) {
          _isAutoSyncing = false;
        }
      });
    }
  }

  // Helper to check if object is still valid
  bool get mounted => _connectivityService != null;

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

      _log.debug('TransactionsProvider', 'Loaded ${localTransactions.length} transactions from local storage (accountId: $accountId)');

      _transactions = localTransactions;
      notifyListeners();

      // If online and force sync, or if local storage is empty, sync from server
      final isOnline = _connectivityService?.isOnline ?? true;
      _log.debug('TransactionsProvider', 'Online: $isOnline, ForceSync: $forceSync, LocalEmpty: ${localTransactions.isEmpty}');

      if (isOnline && (forceSync || localTransactions.isEmpty)) {
        _log.debug('TransactionsProvider', 'Syncing from server for accountId: $accountId');
        final result = await _syncService.syncFromServer(
          accessToken: accessToken,
          accountId: accountId,
        );

        if (result.success) {
          _log.info('TransactionsProvider', 'Sync successful, synced ${result.syncedCount} transactions');
          // Reload from local storage after sync
          final updatedTransactions = await _offlineStorage.getTransactions(
            accountId: accountId,
          );
          _log.debug('TransactionsProvider', 'After sync, loaded ${updatedTransactions.length} transactions from local storage');
          _transactions = updatedTransactions;
          _error = null;
        } else {
          _log.error('TransactionsProvider', 'Sync failed: ${result.error}');
          _error = result.error;
        }
      }
    } catch (e) {
      _log.error('TransactionsProvider', 'Error in fetchTransactions: $e');
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

      _log.info('TransactionsProvider', 'Creating transaction: $name, amount: $amount, online: $isOnline');

      // ALWAYS save locally first (offline-first strategy)
      final localTransaction = await _offlineStorage.saveTransaction(
        accountId: accountId,
        name: name,
        date: date,
        amount: amount,
        currency: currency,
        nature: nature,
        notes: notes,
        syncStatus: SyncStatus.pending, // Start as pending
      );

      _log.info('TransactionsProvider', 'Transaction saved locally with ID: ${localTransaction.localId}');

      // Reload transactions to show the new one immediately
      await fetchTransactions(accessToken: accessToken, accountId: accountId);

      // If online, try to upload in background
      if (isOnline) {
        _log.info('TransactionsProvider', 'Attempting to upload transaction to server...');

        // Don't await - upload in background
        _transactionsService.createTransaction(
          accessToken: accessToken,
          accountId: accountId,
          name: name,
          date: date,
          amount: amount,
          currency: currency,
          nature: nature,
          notes: notes,
        ).then((result) async {
          if (!mounted) return;
          
          if (result['success'] == true) {
            _log.info('TransactionsProvider', 'Transaction uploaded successfully');
            final serverTransaction = result['transaction'] as Transaction;
            // Update local transaction with server ID and mark as synced
            await _offlineStorage.updateTransactionSyncStatus(
              localId: localTransaction.localId,
              syncStatus: SyncStatus.synced,
              serverId: serverTransaction.id,
            );
            // Reload to update UI
            await fetchTransactions(accessToken: accessToken, accountId: accountId);
          } else {
            _log.warning('TransactionsProvider', 'Server upload failed: ${result['error']}. Transaction will sync later.');
          }
        }).catchError((e) {
          if (!mounted) return;
          
          _log.error('TransactionsProvider', 'Exception during upload: $e');
          _error = 'Background sync failed: ${e.toString()}';
          notifyListeners();
        });
      } else {
        _log.info('TransactionsProvider', 'Offline: Transaction will sync when online');
      }

      return true; // Always return true because it's saved locally
    } catch (e) {
      _log.error('TransactionsProvider', 'Failed to create transaction: $e');
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
    if (_isListenerAttached && _connectivityService != null) {
      _connectivityService!.removeListener(_onConnectivityChanged);
      _isListenerAttached = false;
    }
    _connectivityService = null;
    super.dispose();
  }
}
