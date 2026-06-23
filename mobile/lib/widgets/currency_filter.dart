import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'sure_chip.dart';

class CurrencyFilter extends StatelessWidget {
  final Set<String> availableCurrencies;
  final Set<String> selectedCurrencies;
  final ValueChanged<Set<String>> onSelectionChanged;

  const CurrencyFilter({
    super.key,
    required this.availableCurrencies,
    required this.selectedCurrencies,
    required this.onSelectionChanged,
  });

  String _getCurrencySymbol(String currency) {
    switch (currency.toUpperCase()) {
      case 'USD':
        return '\$';
      case 'TWD':
        return 'NT\$';
      case 'BTC':
        return '₿';
      case 'ETH':
        return 'Ξ';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      case 'JPY':
        return '¥';
      case 'CNY':
        return '¥';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (availableCurrencies.length <= 1) {
      return const SizedBox.shrink();
    }

    final sortedCurrencies = availableCurrencies.toList()..sort();
    // Ignore stale codes that are no longer available, otherwise a leftover
    // selection could make length-based "All" detection fire incorrectly.
    final normalizedSelected =
        selectedCurrencies.intersection(availableCurrencies);
    final isAllSelected = normalizedSelected.isEmpty ||
        normalizedSelected.length == availableCurrencies.length;

    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // "All" chip
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SureChip(
              label: l.commonAll,
              selected: isAllSelected,
              onSelected: (_) => onSelectionChanged({}),
            ),
          ),

          // Currency chips
          ...sortedCurrencies.map((currency) {
            final isSelected =
                normalizedSelected.contains(currency) && !isAllSelected;
            final symbol = _getCurrencySymbol(currency);
            final displayText = symbol.isNotEmpty
                ? '$currency ($symbol)'
                : currency;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SureChip(
                label: displayText,
                selected: isSelected,
                onSelected: (_) {
                  final newSelection = Set<String>.from(normalizedSelected);
                  if (isSelected) {
                    newSelection.remove(currency);
                  } else {
                    // If currently showing all, start fresh with just this one
                    if (isAllSelected) {
                      newSelection.clear();
                    }
                    newSelection.add(currency);
                  }
                  // If all currencies selected, treat as "All"
                  if (newSelection.length == availableCurrencies.length &&
                      newSelection.containsAll(availableCurrencies)) {
                    onSelectionChanged({});
                  } else {
                    onSelectionChanged(newSelection);
                  }
                },
              ),
            );
          }),
        ],
      ),
    );
  }
}
