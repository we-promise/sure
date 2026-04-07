import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'log_service.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static final Map<String, Map<String, dynamic>> _memoryTransactions = {};
  static final Map<String, Map<String, dynamic>> _memoryAccounts = {};
  static bool _webStorageLogged = false;
  final LogService _log = LogService.instance;

  DatabaseHelper._init();

  bool get _useInMemoryStore => kIsWeb;

  void _ensureWebStoreReady() {
    if (!_useInMemoryStore || _webStorageLogged) return;
    _webStorageLogged = true;
    _log.info(
      'DatabaseHelper',
      'Using in-memory storage on web (sqflite is not supported in browser builds).',
    );
  }

  int _compareDesc(String? left, String? right) {
    return (right ?? '').compareTo(left ?? '');
  }

  int _compareAsc(String? left, String? right) {
    return (left ?? '').compareTo(right ?? '');
  }

  Future<Database> get database async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      throw StateError('sqflite database is not available on web.');
    }
    if (_database != null) return _database!;
    
    try {
      _database = await _initDB('sure_offline.db');
      return _database!;
    } catch (e, stackTrace) {
      _log.error('DatabaseHelper', 'Error initializing local database sure_offline.db: $e');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'database_helper',
          context: ErrorDescription('while opening sure_offline.db'),
        ),
      );
      rethrow;
    }
  }

  Future<Database> _initDB(String filePath) async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, filePath);

      return await openDatabase(
        path,
        version: 1,
        onCreate: _createDB,
      );
    } catch (e, stackTrace) {
      _log.error('DatabaseHelper', 'Error opening database file "$filePath": $e');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'database_helper',
          context: ErrorDescription('while initializing the sqflite database'),
        ),
      );
      rethrow;
    }
  }

  Future<void> _createDB(Database db, int version) async {
    try {
      // Transactions table
      await db.execute('''
        CREATE TABLE transactions (
          local_id TEXT PRIMARY KEY,
          server_id TEXT,
          account_id TEXT NOT NULL,
          name TEXT NOT NULL,
          date TEXT NOT NULL,
          amount TEXT NOT NULL,
          currency TEXT NOT NULL,
          nature TEXT NOT NULL,
          notes TEXT,
          sync_status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');

      // Accounts table (cached from server)
      await db.execute('''
        CREATE TABLE accounts (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          balance TEXT NOT NULL,
          currency TEXT NOT NULL,
          classification TEXT,
          account_type TEXT NOT NULL,
          synced_at TEXT NOT NULL
        )
      ''');

      // Create indexes for better query performance
      await db.execute('''
        CREATE INDEX idx_transactions_sync_status
        ON transactions(sync_status)
      ''');

      await db.execute('''
        CREATE INDEX idx_transactions_account_id
        ON transactions(account_id)
      ''');

      await db.execute('''
        CREATE INDEX idx_transactions_date
        ON transactions(date DESC)
      ''');

      // Index on server_id for faster lookups by server ID
      await db.execute('''
        CREATE INDEX idx_transactions_server_id
        ON transactions(server_id)
      ''');
    } catch (e, stackTrace) {
      _log.error('DatabaseHelper', 'Error creating local database schema: $e');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'database_helper',
          context: ErrorDescription('while creating tables and indexes'),
        ),
      );
      rethrow;
    }
  }

  // Transaction CRUD operations
  Future<String> insertTransaction(Map<String, dynamic> transaction) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final localId = transaction['local_id'] as String;
      _memoryTransactions[localId] = Map<String, dynamic>.from(transaction);
      return localId;
    }
    final db = await database;
    _log.debug('DatabaseHelper', 'Inserting transaction: local_id=${transaction['local_id']}, account_id="${transaction['account_id']}", server_id=${transaction['server_id']}');
    await db.insert(
      'transactions',
      transaction,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.debug('DatabaseHelper', 'Transaction inserted successfully');
    return transaction['local_id'] as String;
  }

  Future<List<Map<String, dynamic>>> getTransactions({String? accountId}) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final results = _memoryTransactions.values
          .where((transaction) {
            final storedAccountId = transaction['account_id'] as String?;
            return accountId == null || storedAccountId == accountId;
          })
          .map((transaction) => Map<String, dynamic>.from(transaction))
          .toList();
      results.sort((a, b) {
        final dateCompare = _compareDesc(a['date'] as String?, b['date'] as String?);
        if (dateCompare != 0) return dateCompare;
        return _compareDesc(a['created_at'] as String?, b['created_at'] as String?);
      });
      return results;
    }
    final db = await database;

    if (accountId != null) {
      _log.debug('DatabaseHelper', 'Querying transactions WHERE account_id = "$accountId"');
      final results = await db.query(
        'transactions',
        where: 'account_id = ?',
        whereArgs: [accountId],
        orderBy: 'date DESC, created_at DESC',
      );
      _log.debug('DatabaseHelper', 'Query returned ${results.length} results');
      return results;
    } else {
      _log.debug('DatabaseHelper', 'Querying ALL transactions');
      final results = await db.query(
        'transactions',
        orderBy: 'date DESC, created_at DESC',
      );
      _log.debug('DatabaseHelper', 'Query returned ${results.length} results');
      return results;
    }
  }

  Future<Map<String, dynamic>?> getTransactionByLocalId(String localId) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final transaction = _memoryTransactions[localId];
      return transaction != null ? Map<String, dynamic>.from(transaction) : null;
    }
    final db = await database;
    final results = await db.query(
      'transactions',
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );

    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getTransactionByServerId(String serverId) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      for (final transaction in _memoryTransactions.values) {
        if (transaction['server_id'] == serverId) {
          return Map<String, dynamic>.from(transaction);
        }
      }
      return null;
    }
    final db = await database;
    final results = await db.query(
      'transactions',
      where: 'server_id = ?',
      whereArgs: [serverId],
      limit: 1,
    );

    return results.isNotEmpty ? results.first : null;
  }

  Future<List<Map<String, dynamic>>> getPendingTransactions() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final results = _memoryTransactions.values
          .where((transaction) => transaction['sync_status'] == 'pending')
          .map((transaction) => Map<String, dynamic>.from(transaction))
          .toList();
      results.sort(
        (a, b) => _compareAsc(a['created_at'] as String?, b['created_at'] as String?),
      );
      return results;
    }
    final db = await database;
    return await db.query(
      'transactions',
      where: 'sync_status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getPendingDeletes() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final results = _memoryTransactions.values
          .where((transaction) => transaction['sync_status'] == 'pending_delete')
          .map((transaction) => Map<String, dynamic>.from(transaction))
          .toList();
      results.sort(
        (a, b) => _compareAsc(a['updated_at'] as String?, b['updated_at'] as String?),
      );
      return results;
    }
    final db = await database;
    return await db.query(
      'transactions',
      where: 'sync_status = ?',
      whereArgs: ['pending_delete'],
      orderBy: 'updated_at ASC',
    );
  }

  Future<int> updateTransaction(String localId, Map<String, dynamic> transaction) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      if (!_memoryTransactions.containsKey(localId)) {
        return 0;
      }
      final updated = Map<String, dynamic>.from(transaction);
      updated['local_id'] = localId;
      _memoryTransactions[localId] = updated;
      return 1;
    }
    final db = await database;
    return await db.update(
      'transactions',
      transaction,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<int> deleteTransaction(String localId) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      return _memoryTransactions.remove(localId) != null ? 1 : 0;
    }
    final db = await database;
    return await db.delete(
      'transactions',
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<int> deleteTransactionByServerId(String serverId) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      String? localIdToRemove;
      for (final entry in _memoryTransactions.entries) {
        if (entry.value['server_id'] == serverId) {
          localIdToRemove = entry.key;
          break;
        }
      }
      if (localIdToRemove == null) return 0;
      _memoryTransactions.remove(localIdToRemove);
      return 1;
    }
    final db = await database;
    return await db.delete(
      'transactions',
      where: 'server_id = ?',
      whereArgs: [serverId],
    );
  }

  Future<void> clearTransactions() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      _memoryTransactions.clear();
      return;
    }
    final db = await database;
    await db.delete('transactions');
  }

  Future<void> clearSyncedTransactions() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final keysToRemove = _memoryTransactions.entries
          .where((entry) => entry.value['sync_status'] == 'synced')
          .map((entry) => entry.key)
          .toList();
      for (final key in keysToRemove) {
        _memoryTransactions.remove(key);
      }
      return;
    }
    final db = await database;
    _log.debug('DatabaseHelper', 'Clearing only synced transactions, keeping pending/failed');
    await db.delete(
      'transactions',
      where: 'sync_status = ?',
      whereArgs: ['synced'],
    );
  }

  // Account CRUD operations (for caching)
  Future<void> insertAccount(Map<String, dynamic> account) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final id = account['id'] as String;
      _memoryAccounts[id] = Map<String, dynamic>.from(account);
      return;
    }
    final db = await database;
    await db.insert(
      'accounts',
      account,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertAccounts(List<Map<String, dynamic>> accounts) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      for (final account in accounts) {
        final id = account['id'] as String;
        _memoryAccounts[id] = Map<String, dynamic>.from(account);
      }
      return;
    }
    final db = await database;
    final batch = db.batch();

    for (final account in accounts) {
      batch.insert(
        'accounts',
        account,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getAccounts() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final results = _memoryAccounts.values
          .map((account) => Map<String, dynamic>.from(account))
          .toList();
      results.sort(
        (a, b) => _compareAsc(a['name'] as String?, b['name'] as String?),
      );
      return results;
    }
    final db = await database;
    return await db.query('accounts', orderBy: 'name ASC');
  }

  Future<Map<String, dynamic>?> getAccountById(String id) async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      final account = _memoryAccounts[id];
      return account != null ? Map<String, dynamic>.from(account) : null;
    }
    final db = await database;
    final results = await db.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    return results.isNotEmpty ? results.first : null;
  }

  Future<void> clearAccounts() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      _memoryAccounts.clear();
      return;
    }
    final db = await database;
    await db.delete('accounts');
  }

  // Utility methods
  Future<void> clearAllData() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      _memoryTransactions.clear();
      _memoryAccounts.clear();
      return;
    }
    final db = await database;
    await db.delete('transactions');
    await db.delete('accounts');
  }

  Future<void> close() async {
    if (_useInMemoryStore) {
      _ensureWebStoreReady();
      _memoryTransactions.clear();
      _memoryAccounts.clear();
      return;
    }
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
