import 'package:flutter/material.dart';
import '../models/account.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';
import 'money_text.dart';
import 'sure_card.dart';
import 'sure_icon.dart';

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

  String _getAccountIconName() {
    switch (account.accountType) {
      case 'depository':
        return SureIcons.landmark;
      case 'credit_card':
        return SureIcons.creditCard;
      case 'investment':
        return SureIcons.trendingUp;
      case 'loan':
        return SureIcons.receipt;
      case 'property':
        return SureIcons.house;
      case 'vehicle':
        return SureIcons.car;
      case 'crypto':
        return SureIcons.bitcoin;
      case 'other_asset':
        return SureIcons.shapes;
      case 'other_liability':
        return SureIcons.handCoins;
      default:
        return SureIcons.wallet;
    }
  }

  Color _getAccountColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (account.isAsset) {
      return SureColors.of(context).palette.success;
    } else if (account.isLiability) {
      return SureColors.of(context).palette.destructive;
    }
    return colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accountColor = _getAccountColor(context);

    final cardContent = SureCard(
      margin: const EdgeInsets.only(bottom: 12),
      onTap: onTap,
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
            child: SureIcon(
              _getAccountIconName(),
              color: accountColor,
              size: SureIconSize.lg,
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
                    fontWeight: FontWeight.w500,
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
                style: SureMoney.tabular(
                  Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: account.isLiability
                        ? SureColors.of(context).palette.destructive
                        : null,
                  ),
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
            borderRadius: BorderRadius.circular(SureTokens.radiusLg),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SureIcon(
                SureIcons.receipt,
                color: Colors.white,
                size: SureIconSize.xl,
              ),
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
