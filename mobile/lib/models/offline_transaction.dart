import 'dart:convert';

import 'transaction.dart';

enum SyncStatus {
  synced, // Transaction is synced with server
  pending, // Transaction is waiting to be synced (create)
  failed, // Last sync attempt failed
  pendingDelete, // Transaction is waiting to be deleted on server
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
    super.categoryId,
    super.categoryName,
    super.categoryProvided = true,
    super.merchantId,
    super.merchantName,
    super.merchantProvided = true,
    super.tagIds,
    super.tagNames,
    super.tagsProvided = true,
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
      categoryId: transaction.categoryId,
      categoryName: transaction.categoryName,
      categoryProvided: transaction.categoryProvided,
      merchantId: transaction.merchantId,
      merchantName: transaction.merchantName,
      merchantProvided: transaction.merchantProvided,
      tagIds: transaction.tagIds,
      tagNames: transaction.tagNames,
      tagsProvided: transaction.tagsProvided,
      syncStatus: syncStatus,
    );
  }

  factory OfflineTransaction.fromDatabaseMap(Map<String, dynamic> map) {
    final tagIds = _decodeStringList(map['tag_ids'] as String?);
    final tagNames = _decodeStringList(map['tag_names'] as String?);
    final tagsProvided =
        map.containsKey('tag_ids') || map.containsKey('tag_names');

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
      categoryId: map['category_id'] as String?,
      categoryName: map['category_name'] as String?,
      merchantId: map['merchant_id'] as String?,
      merchantName: map['merchant_name'] as String?,
      tagIds: tagIds,
      tagNames: tagNames,
      tagsProvided: tagsProvided,
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
      'category_id': categoryId,
      'category_name': categoryName,
      'merchant_id': merchantId,
      'merchant_name': merchantName,
      'tag_ids': jsonEncode(tagIds),
      'tag_names': jsonEncode(tagNames),
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
      categoryId: categoryId,
      categoryName: categoryName,
      categoryProvided: categoryProvided,
      merchantId: merchantId,
      merchantName: merchantName,
      merchantProvided: merchantProvided,
      tagIds: tagIds,
      tagNames: tagNames,
      tagsProvided: tagsProvided,
    );
  }

  Transaction toTransactionWithSubmittedUpdate({
    String? name,
    String? notes,
    String? categoryId,
    String? merchantId,
    List<String>? tagIds,
  }) {
    final nextTagIds = tagIds ?? this.tagIds;
    final tagNamesById = <String, String>{};
    for (var i = 0; i < this.tagIds.length; i++) {
      tagNamesById[this.tagIds[i]] = i < tagNames.length ? tagNames[i] : '';
    }

    final nextCategoryId = categoryId ?? this.categoryId;
    final nextMerchantId = merchantId ?? this.merchantId;

    return Transaction(
      id: id,
      accountId: accountId,
      name: name ?? this.name,
      date: date,
      amount: amount,
      currency: currency,
      nature: nature,
      notes: notes ?? this.notes,
      categoryId: nextCategoryId,
      categoryName: nextCategoryId == this.categoryId ? categoryName : null,
      categoryProvided: true,
      merchantId: nextMerchantId,
      merchantName: nextMerchantId == this.merchantId ? merchantName : null,
      merchantProvided: true,
      tagIds: nextTagIds,
      tagNames: nextTagIds.map((tagId) => tagNamesById[tagId] ?? '').toList(),
      tagsProvided: true,
    );
  }

  OfflineTransaction mergeServerTransaction(
    Transaction transaction, {
    required String accountId,
  }) {
    return OfflineTransaction(
      id: transaction.id,
      localId: localId,
      accountId: accountId,
      name: transaction.name,
      date: transaction.date,
      amount: transaction.amount,
      currency: transaction.currency,
      nature: transaction.nature,
      notes: transaction.notes,
      categoryId:
          transaction.categoryProvided ? transaction.categoryId : categoryId,
      categoryName: transaction.categoryProvided
          ? transaction.categoryName
          : categoryName,
      merchantId:
          transaction.merchantProvided ? transaction.merchantId : merchantId,
      merchantName: transaction.merchantProvided
          ? transaction.merchantName
          : merchantName,
      tagIds: transaction.tagsProvided ? transaction.tagIds : tagIds,
      tagNames: transaction.tagsProvided ? transaction.tagNames : tagNames,
      syncStatus: SyncStatus.synced,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
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
    String? categoryId,
    String? categoryName,
    bool? categoryProvided,
    String? merchantId,
    String? merchantName,
    bool? merchantProvided,
    List<String>? tagIds,
    List<String>? tagNames,
    bool? tagsProvided,
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
      categoryId: categoryId ?? this.categoryId,
      categoryName: categoryName ?? this.categoryName,
      categoryProvided: categoryProvided ?? this.categoryProvided,
      merchantId: merchantId ?? this.merchantId,
      merchantName: merchantName ?? this.merchantName,
      merchantProvided: merchantProvided ?? this.merchantProvided,
      tagIds: tagIds ?? this.tagIds,
      tagNames: tagNames ?? this.tagNames,
      tagsProvided: tagsProvided ?? this.tagsProvided,
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

  static List<String> _decodeStringList(String? jsonText) {
    if (jsonText == null || jsonText.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is List) {
        return decoded
            .where((item) => item != null)
            .map((item) => item.toString())
            .toList();
      }
    } catch (_) {
      return const [];
    }

    return const [];
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
