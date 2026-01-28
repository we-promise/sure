import 'transaction.dart';

enum SyncStatus {
  synced,         // Transaction is synced with server
  pending,        // Transaction is waiting to be synced (create)
  failed,         // Last sync attempt failed
  pendingDelete,  // Transaction is waiting to be deleted on server
}

class OfflineTransaction extends Transaction {
  final String localId;
  final SyncStatus syncStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  OfflineTransaction({
    super.id,
    required this.localId,
    required super.accountId,
    required super.name,
    required super.date,
    required super.amount,
    required super.currency,
    required super.nature,
    super.notes,
    this.syncStatus = SyncStatus.pending,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  factory OfflineTransaction.fromTransaction(
    Transaction transaction, {
    required String localId,
    SyncStatus syncStatus = SyncStatus.synced,
  }) {
    return OfflineTransaction(
      id: transaction.id,
      localId: localId,
      accountId: transaction.accountId,
      name: transaction.name,
      date: transaction.date,
      amount: transaction.amount,
      currency: transaction.currency,
      nature: transaction.nature,
      notes: transaction.notes,
      syncStatus: syncStatus,
    );
  }

  factory OfflineTransaction.fromDatabaseMap(Map<String, dynamic> map) {
    return OfflineTransaction(
      id: map['server_id'] as String?,
      localId: map['local_id'] as String,
      accountId: map['account_id'] as String,
      name: map['name'] as String,
      date: map['date'] as String,
      amount: map['amount'] as String,
      currency: map['currency'] as String,
      nature: map['nature'] as String,
      notes: map['notes'] as String?,
      syncStatus: _parseSyncStatus(map['sync_status'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  Map<String, dynamic> toDatabaseMap() {
    return {
      'local_id': localId,
      'server_id': id,
      'account_id': accountId,
      'name': name,
      'date': date,
      'amount': amount,
      'currency': currency,
      'nature': nature,
      'notes': notes,
      'sync_status': _syncStatusToString(syncStatus),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Transaction toTransaction() {
    return Transaction(
      id: id,
      accountId: accountId,
      name: name,
      date: date,
      amount: amount,
      currency: currency,
      nature: nature,
      notes: notes,
    );
  }

  OfflineTransaction copyWith({
    String? id,
    String? localId,
    String? accountId,
    String? name,
    String? date,
    String? amount,
    String? currency,
    String? nature,
    String? notes,
    SyncStatus? syncStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return OfflineTransaction(
      id: id ?? this.id,
      localId: localId ?? this.localId,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      date: date ?? this.date,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      nature: nature ?? this.nature,
      notes: notes ?? this.notes,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isSynced => syncStatus == SyncStatus.synced && id != null;
  bool get isPending => syncStatus == SyncStatus.pending;
  bool get hasFailed => syncStatus == SyncStatus.failed;

  static SyncStatus _parseSyncStatus(String status) {
    switch (status) {
      case 'synced':
        return SyncStatus.synced;
      case 'pending':
        return SyncStatus.pending;
      case 'failed':
        return SyncStatus.failed;
      case 'pending_delete':
        return SyncStatus.pendingDelete;
      default:
        return SyncStatus.pending;
    }
  }

  static String _syncStatusToString(SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return 'synced';
      case SyncStatus.pending:
        return 'pending';
      case SyncStatus.failed:
        return 'failed';
      case SyncStatus.pendingDelete:
        return 'pending_delete';
    }
  }
}
