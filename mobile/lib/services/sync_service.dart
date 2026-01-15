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

  /// Sync pending deletes to server (internal method without sync lock check)
  Future<SyncResult> _syncPendingDeletesInternal(String accessToken) async {
    int successCount = 0;
    int failureCount = 0;
    String? lastError;

    try {
      final pendingDeletes = await _offlineStorage.getPendingDeletes();
      _log.info('SyncService', 'Found ${pendingDeletes.length} pending deletes to process');

      if (pendingDeletes.isEmpty) {
        return SyncResult(success: true, syncedCount: 0);
      }

      for (final transaction in pendingDeletes) {
        try {
          // Only attempt to delete on server if the transaction has a server ID
          if (transaction.id != null && transaction.id!.isNotEmpty) {
            _log.info('SyncService', 'Deleting transaction ${transaction.id} from server');
            final result = await _transactionsService.deleteTransaction(
              accessToken: accessToken,
              transactionId: transaction.id!,
            );

            if (result['success'] == true) {
              _log.info('SyncService', 'Delete success! Removing from local storage');
              // Delete from local storage completely
              await _offlineStorage.deleteTransaction(transaction.localId);
              successCount++;
            } else {
              // Mark as failed but keep it as pending delete for retry
              _log.error('SyncService', 'Delete failed: ${result['error']}');
              await _offlineStorage.updateTransactionSyncStatus(
                localId: transaction.localId,
                syncStatus: SyncStatus.failed,
              );
              failureCount++;
              lastError = result['error'] as String?;
            }
          } else {
            // No server ID means it was never synced to server, just delete locally
            _log.info('SyncService', 'Transaction ${transaction.localId} has no server ID, deleting locally only');
            await _offlineStorage.deleteTransaction(transaction.localId);
            successCount++;
          }
        } catch (e) {
          // Mark as failed
          _log.error('SyncService', 'Delete exception: $e');
          await _offlineStorage.updateTransactionSyncStatus(
            localId: transaction.localId,
            syncStatus: SyncStatus.failed,
          );
          failureCount++;
          lastError = e.toString();
        }
      }

      _log.info('SyncService', 'Delete complete: $successCount success, $failureCount failed');

      return SyncResult(
        success: failureCount == 0,
        syncedCount: successCount,
        failedCount: failureCount,
        error: failureCount > 0 ? lastError : null,
      );
    } catch (e) {
      _log.error('SyncService', 'Sync pending deletes exception: $e');
      return SyncResult(
        success: false,
        syncedCount: successCount,
        failedCount: failureCount,
        error: e.toString(),
      );
    }
  }

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
      _log.info('SyncService', '========== SYNC FROM SERVER START ==========');
      _log.info('SyncService', 'Fetching transactions from server (accountId: ${accountId ?? "ALL"})');

      List<Transaction> allTransactions = [];
      int currentPage = 1;
      int totalPages = 1;
      const int perPage = 100; // Use maximum allowed by backend

      // Fetch all pages
      while (currentPage <= totalPages) {
        _log.info('SyncService', '>>> Fetching page $currentPage of $totalPages (perPage: $perPage)');

        final result = await _transactionsService.getTransactions(
          accessToken: accessToken,
          accountId: accountId,
          page: currentPage,
          perPage: perPage,
        );

        _log.debug('SyncService', 'API call completed for page $currentPage, success: ${result['success']}');

        if (result['success'] == true) {
          final pageTransactions = (result['transactions'] as List<dynamic>?)
              ?.cast<Transaction>() ?? [];

          _log.info('SyncService', 'Page $currentPage returned ${pageTransactions.length} transactions');
          allTransactions.addAll(pageTransactions);
          _log.info('SyncService', 'Total transactions accumulated: ${allTransactions.length}');

          // Extract pagination info if available
          final pagination = result['pagination'] as Map<String, dynamic>?;
          if (pagination != null) {
            final prevTotalPages = totalPages;
            totalPages = pagination['total_pages'] as int? ?? 1;
            final totalCount = pagination['total_count'] as int? ?? 0;
            final currentPageFromApi = pagination['page'] as int? ?? currentPage;
            final perPageFromApi = pagination['per_page'] as int? ?? perPage;

            _log.info('SyncService', 'Pagination info: page=$currentPageFromApi/$totalPages, per_page=$perPageFromApi, total_count=$totalCount');

            if (prevTotalPages != totalPages) {
              _log.info('SyncService', 'Total pages updated from $prevTotalPages to $totalPages');
            }
          } else {
            // No pagination info means this is the only page
            _log.warning('SyncService', 'No pagination info in response - assuming single page');
            totalPages = currentPage;
          }

          _log.info('SyncService', 'Moving to next page (current: $currentPage, total: $totalPages)');
          currentPage++;
        } else {
          _log.error('SyncService', 'Server returned error on page $currentPage: ${result['error']}');
          return SyncResult(
            success: false,
            error: result['error'] as String? ?? 'Failed to sync from server',
          );
        }
      }

      _log.info('SyncService', '>>> Pagination loop completed. Fetched ${currentPage - 1} pages');
      _log.info('SyncService', '>>> Received total of ${allTransactions.length} transactions from server');

      // Update local cache with server data
      _log.info('SyncService', '========== UPDATING LOCAL CACHE ==========');
      if (accountId == null) {
        _log.info('SyncService', 'Full sync - clearing and replacing all transactions');
        // Full sync - replace all transactions
        await _offlineStorage.syncTransactionsFromServer(allTransactions);
      } else {
        _log.info('SyncService', 'Partial sync - upserting ${allTransactions.length} transactions for account $accountId');
        // Partial sync - upsert transactions
        int upsertCount = 0;
        for (final transaction in allTransactions) {
          await _offlineStorage.upsertTransactionFromServer(
            transaction,
            accountId: accountId,
          );
          upsertCount++;
          if (upsertCount % 50 == 0) {
            _log.info('SyncService', 'Upserted $upsertCount/${allTransactions.length} transactions');
          }
        }
        _log.info('SyncService', 'Completed upserting $upsertCount transactions');
      }

      _log.info('SyncService', '========== SYNC FROM SERVER COMPLETE ==========');
      _lastSyncTime = DateTime.now();
      notifyListeners();

      return SyncResult(
        success: true,
        syncedCount: allTransactions.length,
      );
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

  /// Full sync - upload pending transactions, process pending deletes, and download from server
  Future<SyncResult> performFullSync(String accessToken) async {
    if (_isSyncing) {
      return SyncResult(success: false, error: 'Sync already in progress');
    }

    _log.info('SyncService', '==== Full Sync Started ====');
    _isSyncing = true;
    _syncError = null;
    notifyListeners();

    try {
      // Step 1: Process pending deletes (do this first to free up resources)
      _log.info('SyncService', 'Step 1: Processing pending deletes');
      final deleteResult = await _syncPendingDeletesInternal(accessToken);
      _log.info('SyncService', 'Step 1 complete: ${deleteResult.syncedCount ?? 0} deleted, ${deleteResult.failedCount ?? 0} failed');

      // Step 2: Upload pending transactions
      _log.info('SyncService', 'Step 2: Uploading pending transactions');
      final uploadResult = await _syncPendingTransactionsInternal(accessToken);
      _log.info('SyncService', 'Step 2 complete: ${uploadResult.syncedCount ?? 0} uploaded, ${uploadResult.failedCount ?? 0} failed');

      // Step 3: Download transactions from server
      _log.info('SyncService', 'Step 3: Downloading transactions from server');
      final downloadResult = await syncFromServer(accessToken: accessToken);
      _log.info('SyncService', 'Step 3 complete: ${downloadResult.syncedCount ?? 0} downloaded');

      // Step 4: Sync accounts
      _log.info('SyncService', 'Step 4: Syncing accounts');
      final accountsResult = await syncAccounts(accessToken);
      _log.info('SyncService', 'Step 4 complete');

      _isSyncing = false;
      _lastSyncTime = DateTime.now();

      final allSuccess = deleteResult.success && uploadResult.success && downloadResult.success && accountsResult.success;
      _syncError = allSuccess ? null : (deleteResult.error ?? uploadResult.error ?? downloadResult.error ?? accountsResult.error);

      _log.info('SyncService', '==== Full Sync Complete: ${allSuccess ? "SUCCESS" : "PARTIAL/FAILED"} ====');

      notifyListeners();

      return SyncResult(
        success: allSuccess,
        syncedCount: (deleteResult.syncedCount ?? 0) + (uploadResult.syncedCount ?? 0) + (downloadResult.syncedCount ?? 0),
        failedCount: (deleteResult.failedCount ?? 0) + (uploadResult.failedCount ?? 0),
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
