import 'package:uuid/uuid.dart';
import '../models/offline_transaction.dart';
import '../models/transaction.dart';
import '../models/account.dart';
import 'database_helper.dart';
import 'log_service.dart';

class OfflineStorageService {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();
  final LogService _log = LogService.instance;

  // Transaction operations
  Future<OfflineTransaction> saveTransaction({
    required String accountId,
    required String name,
    required String date,
    required String amount,
    required String currency,
    required String nature,
    String? notes,
    String? serverId,
    SyncStatus syncStatus = SyncStatus.pending,
  }) async {
    _log.info('OfflineStorage', 'saveTransaction called: name=$name, amount=$amount, accountId=$accountId, syncStatus=$syncStatus');

    final localId = _uuid.v4();
    final transaction = OfflineTransaction(
      id: serverId,
      localId: localId,
      accountId: accountId,
      name: name,
      date: date,
      amount: amount,
      currency: currency,
      nature: nature,
      notes: notes,
      syncStatus: syncStatus,
    );

    try {
      await _dbHelper.insertTransaction(transaction.toDatabaseMap());
      _log.info('OfflineStorage', 'Transaction saved successfully with localId: $localId');
      return transaction;
    } catch (e) {
      _log.error('OfflineStorage', 'Failed to save transaction: $e');
      rethrow;
    }
  }

  Future<List<OfflineTransaction>> getTransactions({String? accountId}) async {
    _log.debug('OfflineStorage', 'getTransactions called with accountId: $accountId');
    final transactionMaps = await _dbHelper.getTransactions(accountId: accountId);
    _log.debug('OfflineStorage', 'Retrieved ${transactionMaps.length} transaction maps from database');

    if (transactionMaps.isNotEmpty && accountId != null) {
      _log.debug('OfflineStorage', 'Sample transaction account_ids:');
      for (int i = 0; i < transactionMaps.take(3).length; i++) {
        final map = transactionMaps[i];
        _log.debug('OfflineStorage', '  - Transaction ${map['server_id']}: account_id="${map['account_id']}"');
      }
    }

    final transactions = transactionMaps
        .map((map) => OfflineTransaction.fromDatabaseMap(map))
        .toList();
    _log.debug('OfflineStorage', 'Returning ${transactions.length} transactions');
    return transactions;
  }

  Future<OfflineTransaction?> getTransactionByLocalId(String localId) async {
    final map = await _dbHelper.getTransactionByLocalId(localId);
    return map != null ? OfflineTransaction.fromDatabaseMap(map) : null;
  }

  Future<OfflineTransaction?> getTransactionByServerId(String serverId) async {
    final map = await _dbHelper.getTransactionByServerId(serverId);
    return map != null ? OfflineTransaction.fromDatabaseMap(map) : null;
  }

  Future<List<OfflineTransaction>> getPendingTransactions() async {
    final transactionMaps = await _dbHelper.getPendingTransactions();
    return transactionMaps
        .map((map) => OfflineTransaction.fromDatabaseMap(map))
        .toList();
  }

  Future<List<OfflineTransaction>> getPendingDeletes() async {
    final transactionMaps = await _dbHelper.getPendingDeletes();
    return transactionMaps
        .map((map) => OfflineTransaction.fromDatabaseMap(map))
        .toList();
  }

  Future<void> updateTransactionSyncStatus({
    required String localId,
    required SyncStatus syncStatus,
    String? serverId,
  }) async {
    final existing = await getTransactionByLocalId(localId);
    if (existing == null) return;

    final updated = existing.copyWith(
      syncStatus: syncStatus,
      id: serverId ?? existing.id,
      updatedAt: DateTime.now(),
    );

    await _dbHelper.updateTransaction(localId, updated.toDatabaseMap());
  }

  Future<void> deleteTransaction(String localId) async {
    await _dbHelper.deleteTransaction(localId);
  }

  Future<void> deleteTransactionByServerId(String serverId) async {
    await _dbHelper.deleteTransactionByServerId(serverId);
  }

  /// Mark a transaction for pending deletion (offline delete)
  Future<void> markTransactionForDeletion(String serverId) async {
    _log.info('OfflineStorage', 'Marking transaction $serverId for pending deletion');

    // Find the transaction by server ID
    final existing = await getTransactionByServerId(serverId);
    if (existing == null) {
      _log.warning('OfflineStorage', 'Transaction $serverId not found, cannot mark for deletion');
      return;
    }

    // Update its sync status to pendingDelete
    final updated = existing.copyWith(
      syncStatus: SyncStatus.pendingDelete,
      updatedAt: DateTime.now(),
    );

    await _dbHelper.updateTransaction(existing.localId, updated.toDatabaseMap());
    _log.info('OfflineStorage', 'Transaction ${existing.localId} marked as pending_delete');
  }

  /// Undo a pending transaction operation (either pending create or pending delete)
  Future<bool> undoPendingTransaction(String localId, SyncStatus currentStatus) async {
    _log.info('OfflineStorage', 'Undoing pending transaction $localId with status $currentStatus');

    final existing = await getTransactionByLocalId(localId);
    if (existing == null) {
      _log.warning('OfflineStorage', 'Transaction $localId not found, cannot undo');
      return false;
    }

    if (currentStatus == SyncStatus.pending) {
      // For pending creates: delete the transaction completely
      _log.info('OfflineStorage', 'Deleting pending create transaction $localId');
      await deleteTransaction(localId);
      return true;
    } else if (currentStatus == SyncStatus.pendingDelete) {
      // For pending deletes: restore to synced status
      _log.info('OfflineStorage', 'Restoring pending delete transaction $localId to synced');
      final updated = existing.copyWith(
        syncStatus: SyncStatus.synced,
        updatedAt: DateTime.now(),
      );
      await _dbHelper.updateTransaction(localId, updated.toDatabaseMap());
      return true;
    }

    _log.warning('OfflineStorage', 'Cannot undo transaction with status $currentStatus');
    return false;
  }

  Future<void> syncTransactionsFromServer(List<Transaction> serverTransactions) async {
    _log.info('OfflineStorage', 'syncTransactionsFromServer called with ${serverTransactions.length} transactions from server');

    // Log first transaction's accountId for debugging
    if (serverTransactions.isNotEmpty) {
      final firstTx = serverTransactions.first;
      _log.info('OfflineStorage', 'First transaction: id=${firstTx.id}, accountId="${firstTx.accountId}", name="${firstTx.name}"');
    }

    // Use upsert logic instead of clear + insert to preserve recently uploaded transactions
    _log.info('OfflineStorage', 'Upserting all transactions from server (preserving pending/failed)');

    int upsertedCount = 0;
    int emptyAccountIdCount = 0;
    for (final transaction in serverTransactions) {
      if (transaction.id != null) {
        if (transaction.accountId.isEmpty) {
          emptyAccountIdCount++;
        }
        await upsertTransactionFromServer(transaction);
        upsertedCount++;
      }
    }

    _log.info('OfflineStorage', 'Upserted $upsertedCount transactions from server');
    if (emptyAccountIdCount > 0) {
      _log.error('OfflineStorage', 'WARNING: $emptyAccountIdCount transactions had EMPTY accountId!');
    }
  }

  Future<void> upsertTransactionFromServer(
    Transaction transaction, {
    String? accountId,
  }) async {
    if (transaction.id == null) {
      _log.warning('OfflineStorage', 'Skipping transaction with null ID');
      return;
    }

    // If accountId is provided and transaction.accountId is empty, use the provided one
    final effectiveAccountId = transaction.accountId.isEmpty && accountId != null
        ? accountId
        : transaction.accountId;

    // Log if transaction has empty accountId
    if (transaction.accountId.isEmpty) {
      _log.warning('OfflineStorage', 'Transaction ${transaction.id} has empty accountId from server! Provided accountId: $accountId, effective: $effectiveAccountId');
    }

    // Check if we already have this transaction
    final existing = await getTransactionByServerId(transaction.id!);

    if (existing != null) {
      // Update existing transaction, preserving its accountId if effectiveAccountId is empty
      final finalAccountId = effectiveAccountId.isEmpty ? existing.accountId : effectiveAccountId;

      if (finalAccountId.isEmpty) {
        _log.error('OfflineStorage', 'CRITICAL: Updating transaction ${transaction.id} with EMPTY accountId!');
      }

      final updated = OfflineTransaction(
        id: transaction.id,
        localId: existing.localId,
        accountId: finalAccountId,
        name: transaction.name,
        date: transaction.date,
        amount: transaction.amount,
        currency: transaction.currency,
        nature: transaction.nature,
        notes: transaction.notes,
        syncStatus: SyncStatus.synced,
      );
      await _dbHelper.updateTransaction(existing.localId, updated.toDatabaseMap());
    } else {
      // Insert new transaction
      if (effectiveAccountId.isEmpty) {
        _log.error('OfflineStorage', 'CRITICAL: Inserting transaction ${transaction.id} with EMPTY accountId!');
      }

      final offlineTransaction = OfflineTransaction(
        id: transaction.id,
        localId: _uuid.v4(),
        accountId: effectiveAccountId,
        name: transaction.name,
        date: transaction.date,
        amount: transaction.amount,
        currency: transaction.currency,
        nature: transaction.nature,
        notes: transaction.notes,
        syncStatus: SyncStatus.synced,
      );
      await _dbHelper.insertTransaction(offlineTransaction.toDatabaseMap());
    }
  }

  Future<void> clearTransactions() async {
    await _dbHelper.clearTransactions();
  }

  // Account operations (for caching)
  Future<void> saveAccount(Account account) async {
    final accountMap = {
      'id': account.id,
      'name': account.name,
      'balance': account.balance,
      'currency': account.currency,
      'classification': account.classification,
      'account_type': account.accountType,
      'synced_at': DateTime.now().toIso8601String(),
    };

    await _dbHelper.insertAccount(accountMap);
  }

  Future<void> saveAccounts(List<Account> accounts) async {
    final accountMaps = accounts.map((account) => {
      'id': account.id,
      'name': account.name,
      'balance': account.balance,
      'currency': account.currency,
      'classification': account.classification,
      'account_type': account.accountType,
      'synced_at': DateTime.now().toIso8601String(),
    }).toList();

    await _dbHelper.insertAccounts(accountMaps);
  }

  Future<List<Account>> getAccounts() async {
    final accountMaps = await _dbHelper.getAccounts();
    return accountMaps.map((map) => Account.fromJson(map)).toList();
  }

  Future<Account?> getAccountById(String id) async {
    final map = await _dbHelper.getAccountById(id);
    return map != null ? Account.fromJson(map) : null;
  }

  Future<void> clearAccounts() async {
    await _dbHelper.clearAccounts();
  }

  // Utility methods
  Future<void> clearAllData() async {
    await _dbHelper.clearAllData();
  }
}
