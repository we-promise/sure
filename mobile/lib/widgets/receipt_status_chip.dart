import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/transaction.dart';
import 'sure_chip.dart';

/// Marks a transaction whose receipt is still being read or needs a look.
/// Renders nothing once the receipt was read cleanly, or without a receipt.
class ReceiptStatusChip extends StatelessWidget {
  final Transaction transaction;

  const ReceiptStatusChip({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (transaction.receiptProcessing) {
      return SureChip(label: l.receiptProcessing, leading: const Icon(Icons.hourglass_top, size: 14));
    }
    if (transaction.receiptNeedsReview) {
      return SureChip(label: l.receiptNeedsReview, leading: const Icon(Icons.error_outline, size: 14));
    }
    return const SizedBox.shrink();
  }
}
