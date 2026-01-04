import 'package:uuid/uuid.dart';
import '../models/offline_transaction.dart';
import '../models/transaction.dart';
import '../models/account.dart';
import 'database_helper.dart';

class OfflineStorageService {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();

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

    await _dbHelper.insertTransaction(transaction.toDatabaseMap());
    return transaction;
  }

  Future<List<OfflineTransaction>> getTransactions({String? accountId}) async {
    final transactionMaps = await _dbHelper.getTransactions(accountId: accountId);
    return transactionMaps
        .map((map) => OfflineTransaction.fromDatabaseMap(map))
        .toList();
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

  Future<void> syncTransactionsFromServer(List<Transaction> serverTransactions) async {
    // Clear existing synced transactions
    await _dbHelper.clearTransactions();

    // Insert all server transactions as synced
    for (final transaction in serverTransactions) {
      if (transaction.id != null) {
        final offlineTransaction = OfflineTransaction.fromTransaction(
          transaction,
          localId: _uuid.v4(),
          syncStatus: SyncStatus.synced,
        );
        await _dbHelper.insertTransaction(offlineTransaction.toDatabaseMap());
      }
    }
  }

  Future<void> upsertTransactionFromServer(
    Transaction transaction, {
    String? accountId,
  }) async {
    if (transaction.id == null) return;

    // If accountId is provided and transaction.accountId is empty, use the provided one
    final effectiveAccountId = transaction.accountId.isEmpty && accountId != null
        ? accountId
        : transaction.accountId;

    // Check if we already have this transaction
    final existing = await getTransactionByServerId(transaction.id!);

    if (existing != null) {
      // Update existing transaction
      final updated = OfflineTransaction(
        id: transaction.id,
        localId: existing.localId,
        accountId: effectiveAccountId,
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
