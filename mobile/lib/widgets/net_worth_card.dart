import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/privacy_provider.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import 'money_text.dart';
import 'sure_icon.dart';

enum AccountFilter { all, assets, liabilities }

class NetWorthCard extends StatelessWidget {
  final Map<String, double> assetTotalsByCurrency;
  final Map<String, double> liabilityTotalsByCurrency;
  final AccountFilter currentFilter;
  final ValueChanged<AccountFilter> onFilterChanged;
  final String Function(String currency, double amount) formatAmount;
  final String? netWorthFormatted;
  final bool isStale;

  const NetWorthCard({
    super.key,
    required this.assetTotalsByCurrency,
    required this.liabilityTotalsByCurrency,
    required this.currentFilter,
    required this.onFilterChanged,
    required this.formatAmount,
    this.netWorthFormatted,
    this.isStale = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;

    return Container(
      key: const ValueKey('netWorthCardChrome'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        // Align the hero card with the Sure card chrome (mirrors SureCard /
        // AccountCard): tokenized container fill, hairline border, the subtle
        // DS shadow, and the canonical radius — instead of Material's
        // surfaceContainerHighest/outline.
        color: palette.container,
        borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        border: Border.all(color: palette.borderSecondary),
        boxShadow: palette.shadowXs,
      ),
      child: Column(
        children: [
          // Net Worth Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Net Worth',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: palette.textSecondary,
                          ),
                    ),
                    if (isStale) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: palette.surfaceInset,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Outdated',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: palette.textSubdued,
                                fontWeight: SureTokens.weightMedium,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  maskedNetWorth,
                  style: SureMoney.tabular(
                    Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: SureTokens.weightMedium,
                          color: isStale
                              ? palette.textSubdued
                              : palette.textPrimary,
                        ),
                  ),
                ),
              ],
            ),
          ),

          // Divider
          Divider(
            height: 1,
            color: palette.borderSecondary,
          ),

          // Assets & Liabilities Row
          IntrinsicHeight(
            child: Row(
              children: [
                // Assets
                Expanded(
                  child: _FilterButton(
                    totals: assetTotalsByCurrency,
                    color: palette.success,
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
                      palette.success,
                    ),
                    formatAmount: maskedFormat,
                  ),
                ),

                // Vertical Divider
                VerticalDivider(
                  width: 1,
                  color: palette.borderSecondary,
                ),

                // Liabilities
                Expanded(
                  child: _FilterButton(
                    totals: liabilityTotalsByCurrency,
                    color: palette.destructive,
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
                      palette.destructive,
                    ),
                    formatAmount: maskedFormat,
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
    String Function(String currency, double amount) formatAmount,
  ) {
    final sortedEntries = totals.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    if (sortedEntries.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final palette = SureColors.of(context).palette;
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
                  color: palette.borderSecondary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // Title with icon
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SureIcon(
                    title == 'Assets'
                        ? SureIcons.trendingUp
                        : SureIcons.trendingDown,
                    color: color,
                    size: SureIconSize.md,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: SureTokens.weightMedium,
                          color: color,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Currency list (scrollable when many entries)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sortedEntries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = sortedEntries[index];
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          entry.key,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: SureTokens.weightMedium,
                                color: palette.textSecondary,
                              ),
                        ),
                        Text(
                          formatAmount(entry.key, entry.value),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: SureTokens.weightMedium,
                                color: palette.textPrimary,
                              ),
                        ),
                      ],
                    );
                  },
                ),
              ),
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
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String Function(String currency, double amount) formatAmount;

  const _FilterButton({
    required this.totals,
    required this.color,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.formatAmount,
  });

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;

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
        child: GestureDetector(
          onTap: onTap,
          onLongPress: sortedEntries.isNotEmpty ? onLongPress : null,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 48,
            child: sortedEntries.isEmpty
                ? Center(
                    child: Text(
                      '--',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: SureTokens.weightMedium,
                            color: palette.textPrimary,
                          ),
                    ),
                  )
                : sortedEntries.length == 1
                    ? Center(
                        child: Text(
                          formatAmount(sortedEntries.first.key, sortedEntries.first.value),
                          style: SureMoney.tabular(
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: SureTokens.weightMedium,
                                  color: palette.textPrimary,
                                ),
                          ),
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: (_) => true,
                        child: ListWheelScrollView.useDelegate(
                          itemExtent: 32,
                          diameterRatio: 1.5,
                          perspective: 0.003,
                          physics: const FixedExtentScrollPhysics(),
                          childDelegate: ListWheelChildBuilderDelegate(
                            childCount: sortedEntries.length,
                            builder: (context, index) {
                              final entry = sortedEntries[index];
                              return Center(
                                child: Text(
                                  formatAmount(entry.key, entry.value),
                                  style: SureMoney.tabular(
                                    Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: SureTokens.weightMedium,
                                          color: palette.textPrimary,
                                        ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
          ),
        ),
      ),
    );
  }
}
