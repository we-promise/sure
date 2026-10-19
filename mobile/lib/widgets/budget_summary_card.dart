import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/budget.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../utils/money_masker.dart';
import 'budget_progress_bar.dart';
import 'money_text.dart';
import 'sure_card.dart';

/// Month totals for a budget: budgeted, actual and remaining spending with an
/// overall progress bar, plus actual vs. expected income.
class BudgetSummaryCard extends StatelessWidget {
  const BudgetSummaryCard({
    super.key,
    required this.budget,
    required this.hideAmounts,
  });

  final Budget budget;
  final bool hideAmounts;

  String _money(String? formatted) =>
      MoneyMasker.mask(formatted ?? '--', hidden: hideAmounts);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = SureColors.of(context).palette;
    final textTheme = Theme.of(context).textTheme;
    final over = budget.isOverBudget;

    return SureCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Stat(
                  label: l.budgetsBudgeted,
                  value: _money(budget.budgetedSpending),
                ),
              ),
              Expanded(
                child: _Stat(
                  label: l.budgetsActual,
                  value: _money(budget.actualSpending),
                ),
              ),
              Expanded(
                child: _Stat(
                  label: l.budgetsRemaining,
                  value: _money(budget.availableToSpend),
                  valueColor: over ? palette.destructive : null,
                  alignEnd: true,
                ),
              ),
            ],
          ),
          if (budget.initialized) ...[
            const SizedBox(height: SureSpacing.lg),
            BudgetProgressBar(
              fraction: budget.spentFraction,
              overBudget: over,
              nearLimit: !over && budget.spentFraction >= 0.9,
              height: 8,
            ),
          ],
          const SizedBox(height: SureSpacing.lg),
          Divider(height: 1, color: palette.borderSecondary),
          const SizedBox(height: SureSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.budgetsIncome,
                style: textTheme.bodyMedium?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(width: SureSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    MoneyText(
                      _money(budget.actualIncome),
                      trend: MoneyTrend.inflow,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: SureTokens.weightMedium,
                      ),
                    ),
                    if (budget.expectedIncome != null)
                      Text(
                        l.budgetsExpectedIncome(_money(budget.expectedIncome)),
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SureMoney.tabular(
                          textTheme.bodySmall?.copyWith(
                            color: palette.textSubdued,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.valueColor,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: palette.textSecondary),
        ),
        const SizedBox(height: SureSpacing.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignEnd
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: Text(
            value,
            maxLines: 1,
            style: SureMoney.tabular(
              textTheme.titleMedium?.copyWith(
                fontWeight: SureTokens.weightSemibold,
                color: valueColor ?? palette.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
