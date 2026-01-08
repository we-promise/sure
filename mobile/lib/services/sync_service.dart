import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/offline_transaction.dart';
import '../models/transaction.dart';
import 'offline_storage_service.dart';
import 'transactions_service.dart';
import 'accounts_service.dart';
import 'connectivity_service.dart';
import 'log_service.dart';

class SyncService with ChangeNotifier {
  final OfflineStorageService _offlineStorage = OfflineStorageService();
  final TransactionsService _transactionsService = TransactionsService();
  final AccountsService _accountsService = AccountsService();
  final LogService _log = LogService.instance;

  bool _isSyncing = false;
  String? _syncError;
  DateTime? _lastSyncTime;

  bool get isSyncing => _isSyncing;
  String? get syncError => _syncError;
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Sync pending transactions to server (internal method without sync lock check)
  Future<SyncResult> _syncPendingTransactionsInternal(String accessToken) async {
    int successCount = 0;
    int failureCount = 0;
    String? lastError;

    try {
      final pendingTransactions = await _offlineStorage.getPendingTransactions();
      _log.info('SyncService', 'Found ${pendingTransactions.length} pending transactions to upload');

      if (pendingTransactions.isEmpty) {
        return SyncResult(success: true, syncedCount: 0);
      }

      for (final transaction in pendingTransactions) {
        try {
          _log.info('SyncService', 'Uploading transaction ${transaction.localId} (${transaction.name})');
          // Upload transaction to server
          final result = await _transactionsService.createTransaction(
            accessToken: accessToken,
            accountId: transaction.accountId,
            name: transaction.name,
            date: transaction.date,
            amount: transaction.amount,
            currency: transaction.currency,
            nature: transaction.nature,
            notes: transaction.notes,
          );

          if (result['success'] == true) {
            // Update local transaction with server ID and mark as synced
            final serverTransaction = result['transaction'] as Transaction;
            _log.info('SyncService', 'Upload success! Server ID: ${serverTransaction.id}');
            await _offlineStorage.updateTransactionSyncStatus(
              localId: transaction.localId,
              syncStatus: SyncStatus.synced,
              serverId: serverTransaction.id,
            );
            successCount++;
          } else {
            // Mark as failed
            _log.error('SyncService', 'Upload failed: ${result['error']}');
            await _offlineStorage.updateTransactionSyncStatus(
              localId: transaction.localId,
              syncStatus: SyncStatus.failed,
            );
            failureCount++;
            lastError = result['error'] as String?;
          }
        } catch (e) {
          // Mark as failed
          _log.error('SyncService', 'Upload exception: $e');
          await _offlineStorage.updateTransactionSyncStatus(
            localId: transaction.localId,
            syncStatus: SyncStatus.failed,
          );
          failureCount++;
          lastError = e.toString();
        }
      }

      _log.info('SyncService', 'Upload complete: $successCount success, $failureCount failed');

      return SyncResult(
        success: failureCount == 0,
        syncedCount: successCount,
        failedCount: failureCount,
        error: failureCount > 0 ? lastError : null,
      );
    } catch (e) {
      _log.error('SyncService', 'Sync pending transactions exception: $e');
      return SyncResult(
        success: false,
        syncedCount: successCount,
        failedCount: failureCount,
        error: e.toString(),
      );
    }
  }

  /// Sync pending transactions to server
  Future<SyncResult> syncPendingTransactions(String accessToken) async {
    if (_isSyncing) {
      return SyncResult(success: false, error: 'Sync already in progress');
    }

    _log.info('SyncService', 'syncPendingTransactions started');
    _isSyncing = true;
    _syncError = null;
    notifyListeners();

    try {
      final result = await _syncPendingTransactionsInternal(accessToken);

      _isSyncing = false;
      _lastSyncTime = DateTime.now();
      _syncError = result.success ? null : result.error;
      notifyListeners();

      return result;
    } catch (e) {
      _log.error('SyncService', 'syncPendingTransactions exception: $e');
      _isSyncing = false;
      _syncError = e.toString();
      notifyListeners();

      return SyncResult(
        success: false,
        error: _syncError,
      );
    }
  }

  /// Download transactions from server and update local cache
  Future<SyncResult> syncFromServer({
    required String accessToken,
    String? accountId,
  }) async {
    try {
      _log.debug('SyncService', 'Fetching transactions from server (accountId: $accountId)');
      final result = await _transactionsService.getTransactions(
        accessToken: accessToken,
        accountId: accountId,
      );

      if (result['success'] == true) {
        final transactions = (result['transactions'] as List<dynamic>?)
            ?.cast<Transaction>() ?? [];

        _log.info('SyncService', 'Received ${transactions.length} transactions from server');

        // Update local cache with server data
        if (accountId == null) {
          _log.debug('SyncService', 'Full sync - clearing and replacing all transactions');
          // Full sync - replace all transactions
          await _offlineStorage.syncTransactionsFromServer(transactions);
        } else {
          _log.debug('SyncService', 'Partial sync - upserting ${transactions.length} transactions for account $accountId');
          // Partial sync - upsert transactions
          for (final transaction in transactions) {
            _log.debug('SyncService', 'Upserting transaction ${transaction.id} (accountId from server: "${transaction.accountId}", provided: "$accountId")');
            await _offlineStorage.upsertTransactionFromServer(
              transaction,
              accountId: accountId,
            );
          }
        }

        _lastSyncTime = DateTime.now();
        notifyListeners();

        return SyncResult(
          success: true,
          syncedCount: transactions.length,
        );
      } else {
        _log.error('SyncService', 'Server returned error: ${result['error']}');
        return SyncResult(
          success: false,
          error: result['error'] as String? ?? 'Failed to sync from server',
        );
      }
    } catch (e) {
      _log.error('SyncService', 'Exception in syncFromServer: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Sync accounts from server and update local cache
  Future<SyncResult> syncAccounts(String accessToken) async {
    try {
      final result = await _accountsService.getAccounts(accessToken: accessToken);

      if (result['success'] == true) {
        final accountsList = result['accounts'] as List<dynamic>? ?? [];

        // Clear and update local account cache
        await _offlineStorage.clearAccounts();

        // The accounts list contains Account objects, not raw JSON
        for (final account in accountsList) {
          await _offlineStorage.saveAccount(account);
        }

        notifyListeners();

        return SyncResult(
          success: true,
          syncedCount: accountsList.length,
        );
      } else {
        return SyncResult(
          success: false,
          error: result['error'] as String? ?? 'Failed to sync accounts',
        );
      }
    } catch (e) {
      return SyncResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Full sync - upload pending transactions and download from server
  Future<SyncResult> performFullSync(String accessToken) async {
    if (_isSyncing) {
      return SyncResult(success: false, error: 'Sync already in progress');
    }

    _log.info('SyncService', '==== Full Sync Started ====');
    _isSyncing = true;
    _syncError = null;
    notifyListeners();

    try {
      // Step 1: Upload pending transactions (use internal method to avoid sync lock check)
      _log.info('SyncService', 'Step 1: Uploading pending transactions');
      final uploadResult = await _syncPendingTransactionsInternal(accessToken);
      _log.info('SyncService', 'Step 1 complete: ${uploadResult.syncedCount ?? 0} uploaded, ${uploadResult.failedCount ?? 0} failed');

      // Step 2: Download transactions from server
      _log.info('SyncService', 'Step 2: Downloading transactions from server');
      final downloadResult = await syncFromServer(accessToken: accessToken);
      _log.info('SyncService', 'Step 2 complete: ${downloadResult.syncedCount ?? 0} downloaded');

      // Step 3: Sync accounts
      _log.info('SyncService', 'Step 3: Syncing accounts');
      await syncAccounts(accessToken);
      _log.info('SyncService', 'Step 3 complete');

      _isSyncing = false;
      _lastSyncTime = DateTime.now();

      final allSuccess = uploadResult.success && downloadResult.success;
      _syncError = allSuccess ? null : (uploadResult.error ?? downloadResult.error);

      _log.info('SyncService', '==== Full Sync Complete: ${allSuccess ? "SUCCESS" : "PARTIAL/FAILED"} ====');

      notifyListeners();

      return SyncResult(
        success: allSuccess,
        syncedCount: (uploadResult.syncedCount ?? 0) + (downloadResult.syncedCount ?? 0),
        failedCount: uploadResult.failedCount,
        error: _syncError,
      );
    } catch (e) {
      _log.error('SyncService', 'Full sync exception: $e');
      _isSyncing = false;
      _syncError = e.toString();
      notifyListeners();

      return SyncResult(
        success: false,
        error: _syncError,
      );
    }
  }

  /// Auto sync if online - to be called when app regains connectivity
  Future<void> autoSync(String accessToken, ConnectivityService connectivityService) async {
    if (connectivityService.isOnline && !_isSyncing) {
      await performFullSync(accessToken);
    }
  }

  void clearSyncError() {
    _syncError = null;
    notifyListeners();
  }
}

class SyncResult {
  final bool success;
  final int? syncedCount;
  final int? failedCount;
  final String? error;

  SyncResult({
    required this.success,
    this.syncedCount,
    this.failedCount,
    this.error,
  });
}
