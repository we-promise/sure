import 'package:flutter/material.dart';
import '../models/offline_transaction.dart';

class SyncStatusBadge extends StatelessWidget {
  final SyncStatus syncStatus;
  final bool compact;

  const SyncStatusBadge({
    super.key,
    required this.syncStatus,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (syncStatus == SyncStatus.synced) {
      return const SizedBox.shrink();
    }

    final Color color;
    final IconData icon;
    final String text;
    final String semanticsLabel;

    switch (syncStatus) {
      case SyncStatus.pending:
        color = Colors.orange;
        icon = Icons.sync;
        text = 'Pending';
        semanticsLabel = 'Transaction pending sync';
        break;
      case SyncStatus.pendingDelete:
        color = Colors.red.shade300;
        icon = Icons.delete_outline;
        text = 'Deleting';
        semanticsLabel = 'Transaction pending deletion';
        break;
      case SyncStatus.failed:
        color = Colors.red;
        icon = Icons.error_outline;
        text = 'Failed';
        semanticsLabel = 'Sync failed';
        break;
      case SyncStatus.synced:
        return const SizedBox.shrink();
    }

    if (compact) {
      return Semantics(
        label: semanticsLabel,
        child: Icon(
          icon,
          size: 16,
          color: color,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Semantics(
        label: semanticsLabel,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
