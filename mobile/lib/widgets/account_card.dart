import 'package:flutter/material.dart';
import '../models/account.dart';

class AccountCard extends StatelessWidget {
  final Account account;
  final VoidCallback? onTap;
  final VoidCallback? onSwipe;

  const AccountCard({
    super.key,
    required this.account,
    this.onTap,
    this.onSwipe,
  });

  IconData _getAccountIcon() {
    switch (account.accountType) {
      case 'depository':
        return Icons.account_balance;
      case 'credit_card':
        return Icons.credit_card;
      case 'investment':
        return Icons.trending_up;
      case 'loan':
        return Icons.receipt_long;
      case 'property':
        return Icons.home;
      case 'vehicle':
        return Icons.directions_car;
      case 'crypto':
        return Icons.currency_bitcoin;
      case 'other_asset':
        return Icons.category;
      case 'other_liability':
        return Icons.payment;
      default:
        return Icons.account_balance_wallet;
    }
  }

  Color _getAccountColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    if (account.isAsset) {
      return Colors.green;
    } else if (account.isLiability) {
      return Colors.red;
    }
    return colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accountColor = _getAccountColor(context);

    final cardContent = Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Account icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accountColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _getAccountIcon(),
                  color: accountColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),

              // Account info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      account.displayAccountType,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

              // Balance
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    account.balance,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: account.isLiability ? Colors.red : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    account.currency,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    // If onSwipe is provided, wrap with Dismissible
    if (onSwipe != null) {
      return Dismissible(
        key: Key('account_${account.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (direction) async {
          // Don't actually dismiss, just trigger the swipe action
          onSwipe?.call();
          return false; // Don't remove the item
        },
        background: Container(
          margin: const EdgeInsets.only(bottom: 12),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.receipt_long, color: Colors.white, size: 28),
              SizedBox(height: 4),
              Text(
                'Transactions',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
        child: cardContent,
      );
    }

    return cardContent;
  }
}
