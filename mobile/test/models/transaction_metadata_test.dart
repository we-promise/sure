import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/offline_transaction.dart';
import 'package:sure_mobile/models/transaction.dart';

void main() {
  group('Transaction metadata', () {
    test('parses merchant and tags from API response', () {
      final transaction = Transaction.fromJson({
        'id': 'tx_1',
        'account': {'id': 'acct_1'},
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'classification': 'expense',
        'notes': 'latte',
        'category': {'id': 'cat_1', 'name': 'Dining'},
        'merchant': {'id': 'merchant_1', 'name': 'Cafe'},
        'tags': [
          {'id': 'tag_1', 'name': 'Work'},
          {'id': 'tag_2', 'name': 'Travel'},
        ],
      });

      expect(transaction.merchantId, 'merchant_1');
      expect(transaction.merchantName, 'Cafe');
      expect(transaction.tagIds, ['tag_1', 'tag_2']);
      expect(transaction.tagNames, ['Work', 'Travel']);
    });

    test('round-trips merchant and tag metadata through offline maps', () {
      final offlineTransaction = OfflineTransaction.fromTransaction(
        Transaction(
          id: 'tx_1',
          accountId: 'acct_1',
          name: 'Coffee',
          date: '2026-06-01',
          amount: r'$4.50',
          currency: 'USD',
          nature: 'expense',
          merchantId: 'merchant_1',
          merchantName: 'Cafe',
          tagIds: const ['tag_1', 'tag_2'],
          tagNames: const ['Work', 'Travel'],
        ),
        localId: 'local_1',
      );

      final restored = OfflineTransaction.fromDatabaseMap(
        offlineTransaction.toDatabaseMap(),
      );

      expect(restored.merchantId, 'merchant_1');
      expect(restored.merchantName, 'Cafe');
      expect(restored.tagIds, ['tag_1', 'tag_2']);
      expect(restored.tagNames, ['Work', 'Travel']);
      expect(restored.syncStatus, SyncStatus.synced);
    });

    test('pending offline replay keeps the stored local id', () {
      final pendingTransaction = OfflineTransaction(
        localId: 'local_123',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: r'$4.50',
        currency: 'USD',
        nature: 'expense',
        syncStatus: SyncStatus.pending,
      );

      final restored = OfflineTransaction.fromDatabaseMap(
        pendingTransaction.toDatabaseMap(),
      );

      expect(restored.localId, 'local_123');
      expect(restored.syncStatus, SyncStatus.pending);
    });

    test('preserves omitted tag state for stored rows without tag columns', () {
      final restored = OfflineTransaction.fromDatabaseMap({
        'server_id': 'tx_1',
        'local_id': 'local_1',
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'notes': null,
        'category_id': null,
        'category_name': null,
        'merchant_id': null,
        'merchant_name': null,
        'sync_status': 'synced',
        'created_at': '2026-06-01T00:00:00.000',
        'updated_at': '2026-06-01T00:00:00.000',
      });

      expect(restored.tagsProvided, false);
      expect(restored.tagIds, isEmpty);
      expect(restored.tagNames, isEmpty);
    });

    test('parses flat merchant and tag fields', () {
      final transaction = Transaction.fromJson({
        'id': 'tx_1',
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'merchant_id': 'merchant_1',
        'merchant_name': 'Cafe',
        'tag_ids': ['tag_1', 'tag_2'],
        'tag_names': ['Work', 'Travel'],
      });

      expect(transaction.merchantId, 'merchant_1');
      expect(transaction.merchantName, 'Cafe');
      expect(transaction.tagIds, ['tag_1', 'tag_2']);
      expect(transaction.tagNames, ['Work', 'Travel']);
    });

    test('normalizes mismatched flat tag name lengths', () {
      final shortNames = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'tag_ids': ['tag_1', 'tag_2'],
        'tag_names': ['Work'],
      });

      final longNames = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'tag_ids': ['tag_1'],
        'tag_names': ['Work', 'Ignored'],
      });

      expect(shortNames.tagNames, ['Work', '']);
      expect(shortNames.tagIds, ['tag_1', 'tag_2']);
      expect(longNames.tagNames, ['Work']);
      expect(longNames.tagIds, ['tag_1']);
    });

    test('filters blank flat tag ids while preserving id-name pairing', () {
      final transaction = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'tag_ids': ['', 'tag_2'],
        'tag_names': ['Ignored', 'Travel'],
      });

      expect(transaction.tagIds, ['tag_2']);
      expect(transaction.tagNames, ['Travel']);
    });

    test('distinguishes omitted tags from explicitly empty tags', () {
      final withoutTags = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
      });

      final clearedTags = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'tags': [],
      });

      expect(withoutTags.tagsProvided, false);
      expect(clearedTags.tagsProvided, true);
    });

    test('distinguishes omitted metadata from explicitly cleared metadata', () {
      final withoutMetadata = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
      });

      final clearedMetadata = Transaction.fromJson({
        'account_id': 'acct_1',
        'name': 'Coffee',
        'date': '2026-06-01',
        'amount': r'$4.50',
        'currency': 'USD',
        'nature': 'expense',
        'category': null,
        'merchant': null,
      });

      expect(withoutMetadata.categoryProvided, false);
      expect(withoutMetadata.merchantProvided, false);
      expect(clearedMetadata.categoryProvided, true);
      expect(clearedMetadata.categoryId, isNull);
      expect(clearedMetadata.categoryName, isNull);
      expect(clearedMetadata.merchantProvided, true);
      expect(clearedMetadata.merchantId, isNull);
      expect(clearedMetadata.merchantName, isNull);
    });

    test('server sync merge preserves omitted metadata and applies clears', () {
      final existing = OfflineTransaction(
        id: 'tx_1',
        localId: 'local_1',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: r'$4.50',
        currency: 'USD',
        nature: 'expense',
        categoryId: 'cat_1',
        categoryName: 'Dining',
        merchantId: 'merchant_1',
        merchantName: 'Cafe',
        tagIds: const ['tag_1'],
        tagNames: const ['Work'],
      );

      final omittedMetadata = existing.mergeServerTransaction(
        Transaction.fromJson({
          'id': 'tx_1',
          'account_id': 'acct_1',
          'name': 'Coffee',
          'date': '2026-06-01',
          'amount': r'$4.50',
          'currency': 'USD',
          'nature': 'expense',
        }),
        accountId: 'acct_1',
      );

      expect(omittedMetadata.categoryId, 'cat_1');
      expect(omittedMetadata.categoryName, 'Dining');
      expect(omittedMetadata.merchantId, 'merchant_1');
      expect(omittedMetadata.merchantName, 'Cafe');
      expect(omittedMetadata.tagIds, ['tag_1']);
      expect(omittedMetadata.tagNames, ['Work']);

      final clearedMetadata = existing.mergeServerTransaction(
        Transaction.fromJson({
          'id': 'tx_1',
          'account_id': 'acct_1',
          'name': 'Coffee',
          'date': '2026-06-01',
          'amount': r'$4.50',
          'currency': 'USD',
          'nature': 'expense',
          'category': null,
          'merchant': null,
          'tags': [],
        }),
        accountId: 'acct_1',
      );

      expect(clearedMetadata.categoryId, isNull);
      expect(clearedMetadata.categoryName, isNull);
      expect(clearedMetadata.merchantId, isNull);
      expect(clearedMetadata.merchantName, isNull);
      expect(clearedMetadata.tagIds, isEmpty);
      expect(clearedMetadata.tagNames, isEmpty);
    });

    test('submitted update fallback preserves account and unchanged labels',
        () {
      final existing = OfflineTransaction(
        id: 'tx_1',
        localId: 'local_1',
        accountId: 'acct_1',
        name: 'Coffee',
        date: '2026-06-01',
        amount: r'$4.50',
        currency: 'USD',
        nature: 'expense',
        notes: 'latte',
        categoryId: 'cat_1',
        categoryName: 'Dining',
        merchantId: 'merchant_1',
        merchantName: 'Cafe',
        tagIds: const ['tag_1', 'tag_2'],
        tagNames: const ['Work', 'Travel'],
      );

      final updated = existing.toTransactionWithSubmittedUpdate(
        name: 'Morning coffee',
        notes: '',
        categoryId: 'cat_2',
        merchantId: 'merchant_1',
        tagIds: const ['tag_2'],
      );

      expect(updated.id, 'tx_1');
      expect(updated.accountId, 'acct_1');
      expect(updated.name, 'Morning coffee');
      expect(updated.notes, '');
      expect(updated.categoryId, 'cat_2');
      expect(updated.categoryName, isNull);
      expect(updated.merchantId, 'merchant_1');
      expect(updated.merchantName, 'Cafe');
      expect(updated.tagIds, ['tag_2']);
      expect(updated.tagNames, ['Travel']);
    });
  });
}
