import 'package:flutter/material.dart';

enum AccountFilter { all, assets, liabilities }

class NetWorthCard extends StatelessWidget {
  final Map<String, double> assetTotalsByCurrency;
  final Map<String, double> liabilityTotalsByCurrency;
  final AccountFilter currentFilter;
  final ValueChanged<AccountFilter> onFilterChanged;
  final String Function(String currency, double amount) formatAmount;

  const NetWorthCard({
    super.key,
    required this.assetTotalsByCurrency,
    required this.liabilityTotalsByCurrency,
    required this.currentFilter,
    required this.onFilterChanged,
    required this.formatAmount,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          // Net Worth Section (Placeholder)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              children: [
                Text(
                  'Net Worth',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '--',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                ),
                Text(
                  'Coming soon',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                ),
              ],
            ),
          ),

          // Divider
          Divider(
            height: 1,
            color: colorScheme.outline.withValues(alpha: 0.2),
          ),

          // Assets & Liabilities Row
          IntrinsicHeight(
            child: Row(
              children: [
                // Assets
                Expanded(
                  child: _FilterButton(
                    label: 'Assets',
                    totals: assetTotalsByCurrency,
                    color: Colors.green,
                    isSelected: currentFilter == AccountFilter.assets,
                    onTap: () {
                      if (currentFilter == AccountFilter.assets) {
                        onFilterChanged(AccountFilter.all);
                      } else {
                        onFilterChanged(AccountFilter.assets);
                      }
                    },
                    formatAmount: formatAmount,
                  ),
                ),

                // Vertical Divider
                VerticalDivider(
                  width: 1,
                  color: colorScheme.outline.withValues(alpha: 0.2),
                ),

                // Liabilities
                Expanded(
                  child: _FilterButton(
                    label: 'Liabilities',
                    totals: liabilityTotalsByCurrency,
                    color: Colors.red,
                    isSelected: currentFilter == AccountFilter.liabilities,
                    onTap: () {
                      if (currentFilter == AccountFilter.liabilities) {
                        onFilterChanged(AccountFilter.all);
                      } else {
                        onFilterChanged(AccountFilter.liabilities);
                      }
                    },
                    formatAmount: formatAmount,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final String label;
  final Map<String, double> totals;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  final String Function(String currency, double amount) formatAmount;

  const _FilterButton({
    required this.label,
    required this.totals,
    required this.color,
    required this.isSelected,
    required this.onTap,
    required this.formatAmount,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Sort currencies by value (descending)
    final sortedEntries = totals.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    return Material(
      color: isSelected ? color.withValues(alpha: 0.1) : Colors.transparent,
      borderRadius: BorderRadius.circular(0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Label with selection indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      size: 14,
                      color: color,
                    ),
                  if (isSelected) const SizedBox(width: 4),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: isSelected ? color : colorScheme.onSurfaceVariant,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Currency totals
              if (sortedEntries.isEmpty)
                Text(
                  '--',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                )
              else
                ...sortedEntries.take(3).map((entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        formatAmount(entry.key, entry.value),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                        textAlign: TextAlign.center,
                      ),
                    )),
              if (sortedEntries.length > 3)
                Text(
                  '+${sortedEntries.length - 3} more',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
