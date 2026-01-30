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
                    totals: assetTotalsByCurrency,
                    color: Colors.green,
                    icon: Icons.trending_up,
                    isSelected: currentFilter == AccountFilter.assets,
                    onTap: () {
                      if (currentFilter == AccountFilter.assets) {
                        onFilterChanged(AccountFilter.all);
                      } else {
                        onFilterChanged(AccountFilter.assets);
                      }
                    },
                    onLongPress: () => _showCurrencyBreakdown(
                      context,
                      'Assets',
                      assetTotalsByCurrency,
                      Colors.green,
                    ),
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
                    totals: liabilityTotalsByCurrency,
                    color: Colors.red,
                    icon: Icons.trending_down,
                    isSelected: currentFilter == AccountFilter.liabilities,
                    onTap: () {
                      if (currentFilter == AccountFilter.liabilities) {
                        onFilterChanged(AccountFilter.all);
                      } else {
                        onFilterChanged(AccountFilter.liabilities);
                      }
                    },
                    onLongPress: () => _showCurrencyBreakdown(
                      context,
                      'Liabilities',
                      liabilityTotalsByCurrency,
                      Colors.red,
                    ),
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

  void _showCurrencyBreakdown(
    BuildContext context,
    String title,
    Map<String, double> totals,
    Color color,
  ) {
    final sortedEntries = totals.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    if (sortedEntries.isEmpty) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // Title with icon
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    title == 'Assets' ? Icons.trending_up : Icons.trending_down,
                    color: color,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Currency list
              ...sortedEntries.map((entry) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          entry.key,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: colorScheme.onSurfaceVariant,
                              ),
                        ),
                        Text(
                          formatAmount(entry.key, entry.value),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ],
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

class _FilterButton extends StatelessWidget {
  final Map<String, double> totals;
  final Color color;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String Function(String currency, double amount) formatAmount;

  const _FilterButton({
    required this.totals,
    required this.color,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.formatAmount,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Sort currencies by value (descending)
    final sortedEntries = totals.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: color.withValues(alpha: 0.6),
            width: 3,
          ),
        ),
      ),
      child: Material(
        color: isSelected ? color.withValues(alpha: 0.1) : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: sortedEntries.isNotEmpty ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Background icon as visual indicator
                Icon(
                  icon,
                  size: 20,
                  color: isSelected
                      ? color
                      : color.withValues(alpha: 0.4),
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
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '+${sortedEntries.length - 3} more',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
