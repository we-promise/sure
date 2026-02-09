import 'package:flutter/material.dart';

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
    if (availableCurrencies.length <= 1) {
      return const SizedBox.shrink();
    }

    final sortedCurrencies = availableCurrencies.toList()..sort();
    final colorScheme = Theme.of(context).colorScheme;
    final isAllSelected = selectedCurrencies.isEmpty ||
        selectedCurrencies.length == availableCurrencies.length;

    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // "All" chip
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('All'),
              selected: isAllSelected,
              onSelected: (_) {
                onSelectionChanged({});
              },
              backgroundColor: colorScheme.surfaceContainerHighest,
              selectedColor: colorScheme.primaryContainer,
              checkmarkColor: colorScheme.onPrimaryContainer,
              labelStyle: TextStyle(
                color: isAllSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
                fontWeight: isAllSelected ? FontWeight.bold : FontWeight.normal,
              ),
              side: BorderSide(
                color: isAllSelected
                    ? colorScheme.primary
                    : colorScheme.outline.withValues(alpha: 0.3),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),

          // Currency chips
          ...sortedCurrencies.map((currency) {
            final isSelected =
                selectedCurrencies.contains(currency) && !isAllSelected;
            final symbol = _getCurrencySymbol(currency);
            final displayText = symbol.isNotEmpty ? '$currency ($symbol)' : currency;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(displayText),
                selected: isSelected,
                onSelected: (_) {
                  final newSelection = Set<String>.from(selectedCurrencies);
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
                  if (newSelection.length == availableCurrencies.length) {
                    onSelectionChanged({});
                  } else {
                    onSelectionChanged(newSelection);
                  }
                },
                backgroundColor: colorScheme.surfaceContainerHighest,
                selectedColor: colorScheme.primaryContainer,
                checkmarkColor: colorScheme.onPrimaryContainer,
                labelStyle: TextStyle(
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                side: BorderSide(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.outline.withValues(alpha: 0.3),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            );
          }),
        ],
      ),
    );
  }
}
