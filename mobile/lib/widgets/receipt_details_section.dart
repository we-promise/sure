import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/transaction.dart';
import '../utils/money_masker.dart';

/// The receipt behind a transaction: its photos, what still needs checking,
/// and the items read from it.
class ReceiptDetailsSection extends StatelessWidget {
  final TransactionReceipt? receipt;

  /// API credentials for loading the photos; the attachment URLs are API routes.
  final Map<String, String>? imageHeaders;

  /// Privacy mode: item amounts are masked like every other amount.
  final bool hideAmounts;

  const ReceiptDetailsSection(
      {super.key,
      required this.receipt,
      this.imageHeaders,
      this.hideAmounts = false});

  @override
  Widget build(BuildContext context) {
    final receipt = this.receipt;
    if (receipt == null ||
        (receipt.status == null && receipt.attachments.isEmpty)) {
      return const SizedBox.shrink();
    }

    final l = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final images =
        receipt.attachments.where((attachment) => attachment.isImage).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(l.receiptSectionTitle,
                        style: textTheme.titleMedium)),
                if (receipt.status == 'processing')
                  Text(l.receiptProcessing, style: textTheme.labelMedium),
                if (receipt.status == 'needs_review')
                  Text(l.receiptNeedsReview,
                      style: textTheme.labelMedium
                          ?.copyWith(color: colorScheme.error)),
                if (receipt.status == 'failed')
                  Text(l.receiptFailed,
                      style: textTheme.labelMedium
                          ?.copyWith(color: colorScheme.error)),
              ],
            ),
            for (final reason in receipt.reviewReasons)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_humanize(reason),
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.error)),
              ),
            if (images.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  // NetworkImage ignores headers when comparing images, so a photo first
                  // requested without credentials would never be requested again with them.
                  itemBuilder: (context, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: imageHeaders == null
                        ? const SizedBox(
                            width: 90,
                            height: 120,
                            child: Icon(Icons.receipt_long_outlined))
                        : Image.network(
                            images[index].thumbnailUrl ?? images[index].url,
                            headers: imageHeaders,
                            width: 90,
                            height: 120,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(
                                width: 90,
                                height: 120,
                                child: Icon(Icons.receipt_long_outlined)),
                          ),
                  ),
                ),
              ),
            ],
            if (receipt.lineItems.isNotEmpty) const SizedBox(height: 12),
            for (final item in receipt.lineItems)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(item.name),
                subtitle:
                    item.categoryName == null ? null : Text(item.categoryName!),
                trailing: item.amount == null
                    ? null
                    : Text(MoneyMasker.mask(item.amount!, hidden: hideAmounts)),
              ),
          ],
        ),
      ),
    );
  }

  // Review reasons come as API keys (items_total_mismatch); the web app shows
  // the full sentences.
  static String _humanize(String reason) {
    final text = reason.replaceAll('_', ' ');
    return text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
  }
}
