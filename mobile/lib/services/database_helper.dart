import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/transaction.dart';
import '../models/account.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('sure_offline.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
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
  }

  // Transaction CRUD operations
  Future<String> insertTransaction(Map<String, dynamic> transaction) async {
    final db = await database;
    await db.insert(
      'transactions',
      transaction,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return transaction['local_id'] as String;
  }

  Future<List<Map<String, dynamic>>> getTransactions({String? accountId}) async {
    final db = await database;

    if (accountId != null) {
      return await db.query(
        'transactions',
        where: 'account_id = ?',
        whereArgs: [accountId],
        orderBy: 'date DESC, created_at DESC',
      );
    } else {
      return await db.query(
        'transactions',
        orderBy: 'date DESC, created_at DESC',
      );
    }
  }

  Future<Map<String, dynamic>?> getTransactionByLocalId(String localId) async {
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
    final db = await database;
    return await db.query(
      'transactions',
      where: 'sync_status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
    );
  }

  Future<int> updateTransaction(String localId, Map<String, dynamic> transaction) async {
    final db = await database;
    return await db.update(
      'transactions',
      transaction,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<int> deleteTransaction(String localId) async {
    final db = await database;
    return await db.delete(
      'transactions',
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<int> deleteTransactionByServerId(String serverId) async {
    final db = await database;
    return await db.delete(
      'transactions',
      where: 'server_id = ?',
      whereArgs: [serverId],
    );
  }

  Future<void> clearTransactions() async {
    final db = await database;
    await db.delete('transactions');
  }

  // Account CRUD operations (for caching)
  Future<void> insertAccount(Map<String, dynamic> account) async {
    final db = await database;
    await db.insert(
      'accounts',
      account,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertAccounts(List<Map<String, dynamic>> accounts) async {
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
    final db = await database;
    return await db.query('accounts', orderBy: 'name ASC');
  }

  Future<Map<String, dynamic>?> getAccountById(String id) async {
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
    final db = await database;
    await db.delete('accounts');
  }

  // Utility methods
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('transactions');
    await db.delete('accounts');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
