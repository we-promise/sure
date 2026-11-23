import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/offline_transaction.dart';
import 'package:sure_mobile/models/transaction.dart';

void main() {
  Map<String, dynamic> base() => {
        'id': 'tx_1',
        'account': {'id': 'acct_1'},
        'name': 'Corner Grocer',
        'date': '2026-11-14',
        'amount': r'$50.00',
        'currency': 'USD',
        'classification': 'expense',
      };

  test('parses receipt status, reasons, items and attachments', () {
    final transaction = Transaction.fromJson({
      ...base(),
      'receipt': {
        'status': 'needs_review',
        'merchant': 'Corner Grocer',
        'review_reasons': [
          {'reason': 'items_total_mismatch', 'total': '50.0'},
        ],
        'line_items': [
          {'name': 'Cheese', 'amount': '30.00', 'category_name': 'Food & Drink'},
        ],
      },
      'attachments': [
        {
          'id': 'att_1',
          'filename': 'r.jpg',
          'content_type': 'image/jpeg',
          'url': 'https://example.com/r.jpg',
          'thumbnail_url': 'https://example.com/r_thumb.jpg',
        },
      ],
    });

    expect(transaction.receiptStatus, 'needs_review');
    expect(transaction.receiptNeedsReview, isTrue);
    expect(transaction.receiptProcessing, isFalse);
    expect(transaction.receiptReviewReasons, ['items_total_mismatch']);
    expect(transaction.receiptLineItems.single.name, 'Cheese');
    expect(transaction.receiptLineItems.single.amount, '30.00');
    expect(transaction.receiptLineItems.single.categoryName, 'Food & Drink');
    expect(transaction.attachments.single.url, 'https://example.com/r.jpg');
    expect(transaction.attachments.single.isImage, isTrue);
  });

  test('a transaction without a receipt has no receipt state', () {
    final transaction = Transaction.fromJson({...base(), 'receipt': null});

    expect(transaction.receiptStatus, isNull);
    expect(transaction.receiptNeedsReview, isFalse);
    expect(transaction.receiptLineItems, isEmpty);
    expect(transaction.attachments, isEmpty);
  });

  test('receipt survives the offline database round trip and server merges', () {
    final fromServer = Transaction.fromJson({
      ...base(),
      'receipt': {
        'status': 'processing',
        'review_reasons': [],
        'line_items': [
          {'name': 'Cheese', 'amount': '30.00', 'category_name': 'Food & Drink'},
        ],
      },
      'attachments': [
        {'id': 'a', 'filename': 'r.jpg', 'content_type': 'image/jpeg', 'url': 'https://example.com/r.jpg'},
      ],
    });

    final stored = OfflineTransaction.fromDatabaseMap(
      OfflineTransaction.fromTransaction(fromServer, localId: 'local_1').toDatabaseMap(),
    );
    final restored = stored.toTransaction();

    expect(restored.receiptProcessing, isTrue);
    expect(restored.receiptLineItems.single.name, 'Cheese');
    expect(restored.attachments.single.url, 'https://example.com/r.jpg');

    expect(stored.copyWith(syncStatus: SyncStatus.pending).toTransaction().receiptProcessing, isTrue);

    final read = Transaction.fromJson({
      ...base(),
      'receipt': {'status': 'completed', 'review_reasons': [], 'line_items': []},
    });
    expect(stored.mergeServerTransaction(read, accountId: 'acct_1').toTransaction().receiptStatus, 'completed');
  });

  test('a locally applied edit keeps the receipt', () {
    final fromServer = Transaction.fromJson({
      ...base(),
      'receipt': {'status': 'completed', 'review_reasons': [], 'line_items': []},
    });

    final edited = OfflineTransaction.fromTransaction(fromServer, localId: 'local_1')
        .toTransactionWithSubmittedUpdate(name: 'Grocer');

    expect(edited.name, 'Grocer');
    expect(edited.receiptStatus, 'completed');
  });
}
