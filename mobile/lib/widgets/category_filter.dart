import 'package:flutter/material.dart' hide Category;
import '../models/category.dart';

class CategoryFilter extends StatelessWidget {
  final List<Category> availableCategories;
  final Set<String> selectedCategoryIds;
  final ValueChanged<Set<String>> onSelectionChanged;

  const CategoryFilter({
    super.key,
    required this.availableCategories,
    required this.selectedCategoryIds,
    required this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (availableCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final isAllSelected = selectedCategoryIds.isEmpty;

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

          // Category chips
          ...availableCategories.map((category) {
            final isSelected =
                selectedCategoryIds.contains(category.id) && !isAllSelected;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(category.name),
                selected: isSelected,
                onSelected: (_) {
                  final newSelection = Set<String>.from(selectedCategoryIds);
                  if (isSelected) {
                    newSelection.remove(category.id);
                  } else {
                    if (isAllSelected) {
                      newSelection.clear();
                    }
                    newSelection.add(category.id);
                  }
                  if (newSelection.length == availableCategories.length) {
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
