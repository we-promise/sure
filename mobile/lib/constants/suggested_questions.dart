import 'package:flutter/material.dart';

/// Suggested questions shown on the empty chat screen.
///
/// l10n upgrade path: when Flutter localisation is added to the mobile app,
/// replace this const list with a function that accepts [BuildContext] and
/// returns localised strings via AppLocalizations. The call site in
/// _EmptyState requires only a one-line change.
const List<({IconData icon, String text})> suggestedQuestions = [
  (icon: Icons.account_balance_wallet_outlined, text: 'What is my current net worth?'),
  (icon: Icons.show_chart,                      text: 'How has my spending changed this month?'),
  (icon: Icons.savings_outlined,                text: 'How can I improve my savings rate?'),
  (icon: Icons.receipt_long_outlined,           text: 'What are my biggest expenses lately?'),
];
