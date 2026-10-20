import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';

/// Thin horizontal bar showing how much of a budget is spent.
///
/// [fraction] is spent / available (1.0 == 100%). The fill is capped at full
/// width; colour follows the web budget card: the category colour while on
/// track, `warning` when near the limit and `destructive` once over.
class BudgetProgressBar extends StatelessWidget {
  const BudgetProgressBar({
    super.key,
    required this.fraction,
    this.color,
    this.overBudget = false,
    this.nearLimit = false,
    this.height = 6,
  });

  final double fraction;
  final Color? color;
  final bool overBudget;
  final bool nearLimit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final fill = overBudget
        ? palette.destructive
        : nearLimit
            ? palette.warning
            : (color ?? palette.success);
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);

    return Semantics(
      value: '${(clamped * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: palette.surfaceInset),
              FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: clamped,
                child: ColoredBox(color: fill),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Parses a category colour as sent by the API (`#RRGGBB`), or null.
Color? parseCategoryColor(String? hex) {
  if (hex == null) return null;
  var value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 3) {
    value = value.split('').map((c) => '$c$c').join();
  }
  if (value.length != 6) return null;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}
