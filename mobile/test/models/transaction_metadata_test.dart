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
  });
}
