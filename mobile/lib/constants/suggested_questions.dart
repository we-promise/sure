import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Suggested questions shown on the empty chat screen.
List<({IconData icon, String text})> suggestedQuestions(BuildContext context) {
  final l = AppLocalizations.of(context);
  return [
    (icon: Icons.account_balance_wallet_outlined, text: l.chatSuggestionNetWorth),
    (icon: Icons.show_chart,                      text: l.chatSuggestionSpending),
    (icon: Icons.savings_outlined,                text: l.chatSuggestionSavings),
    (icon: Icons.receipt_long_outlined,           text: l.chatSuggestionExpenses),
  ];
}
