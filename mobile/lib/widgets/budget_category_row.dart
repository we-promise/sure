import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/budget.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import 'budget_progress_bar.dart';
import 'money_text.dart';

/// One budget category line: name, spent-of-budget progress bar and what is
/// left (or how far over). Subcategories render indented under their parent.
class BudgetCategoryRow extends StatelessWidget {
  const BudgetCategoryRow({
    super.key,
    required this.budgetCategory,
    required this.hideAmounts,
    this.onTap,
    this.indented = false,
  });

  final BudgetCategory budgetCategory;
  final bool hideAmounts;
  final VoidCallback? onTap;
  final bool indented;

  String _money(String? formatted) =>
      MoneyMasker.mask(formatted ?? '--', hidden: hideAmounts);

  /// The API formats an overspend as a negative amount; show its magnitude.
  static String _abs(String formatted) =>
      formatted.replaceFirst(RegExp('^[-\u2212]'), '');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final textTheme = Theme.of(context).textTheme;
    final bc = budgetCategory;
    final color = parseCategoryColor(bc.category.color) ?? palette.textSubdued;
    final over = bc.hasDerivedAmounts && bc.isOverBudget;
    final near = bc.hasDerivedAmounts && bc.isNearLimit;

    final String trailing;
    Color trailingColor = palette.textSecondary;
    if (!bc.hasDerivedAmounts) {
      trailing = '';
    } else if (bc.inheritsParentBudget) {
      trailing = l.budgetsSharedBudget;
      if (over) trailingColor = palette.destructive;
    } else if (!bc.isBudgeted) {
      trailing = l.budgetsNoLimit;
      if (over) trailingColor = palette.destructive;
    } else if (over) {
      trailing = l.budgetsOverBy(_money(_abs(bc.availableToSpend ?? '')));
      trailingColor = palette.destructive;
    } else {
      trailing = l.budgetsAmountLeft(_money(bc.availableToSpend));
    }

    final spentLine = bc.hasDerivedAmounts
        ? (bc.isBudgeted && !bc.inheritsParentBudget
            ? '${_money(bc.actualSpending)} '
                '${l.budgetsOfAmount(_money(bc.displayBudgetedSpending))}'
            : _money(bc.actualSpending))
        : l.budgetsOfAmount(_money(bc.displayBudgetedSpending));

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          indented ? SureSpacing.xl + SureSpacing.huge : SureSpacing.xl,
          SureSpacing.lg,
          SureSpacing.xl,
          SureSpacing.lg,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CategoryAvatar(
              name: bc.name,
              color: color,
              size: indented ? 28 : 36,
            ),
            const SizedBox(width: SureSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          bc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: SureTokens.weightMedium,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      if (over)
                        _Badge(
                          label: l.budgetsOverBudget,
                          color: palette.destructive,
                        )
                      else if (near)
                        _Badge(
                          label: l.budgetsNearLimit,
                          color: palette.warning,
                        ),
                    ],
                  ),
                  const SizedBox(height: SureSpacing.sm),
                  BudgetProgressBar(
                    fraction: bc.spentFraction,
                    color: color,
                    overBudget: over,
                    nearLimit: near,
                    hidden: hideAmounts,
                  ),
                  const SizedBox(height: SureSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          spentLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SureMoney.tabular(
                            textTheme.bodySmall?.copyWith(
                              color: palette.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      if (trailing.isNotEmpty) ...[
                        const SizedBox(width: SureSpacing.md),
                        Expanded(
                          child: Text(
                            trailing,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: SureMoney.tabular(
                              textTheme.bodySmall?.copyWith(
                                color: trailingColor,
                                fontWeight:
                                    over ? SureTokens.weightMedium : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (bc.hasDerivedAmounts &&
                      !bc.inheritsParentBudget &&
                      (bc.rolledOverAmountCents ?? 0) > 0) ...[
                    const SizedBox(height: SureSpacing.xs),
                    Text(
                      l.budgetsRolledOver(_money(bc.rolledOverAmount)),
                      style: SureMoney.tabular(
                        textTheme.bodySmall?.copyWith(
                          color: palette.textSubdued,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryAvatar extends StatelessWidget {
  const _CategoryAvatar({
    required this.name,
    required this.color,
    required this.size,
  });

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    // First user-perceived character, so a name starting with an emoji (a
    // surrogate pair or a ZWJ sequence) isn't cut in half.
    final trimmed = name.trim();
    final initial =
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontWeight: SureTokens.weightSemibold,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.only(start: SureSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: SureSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(SureTokens.radiusMd),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: SureTokens.weightMedium,
            ),
      ),
    );
  }
}
