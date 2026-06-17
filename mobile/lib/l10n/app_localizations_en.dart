// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Sure Finances';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonTryAgain => 'Try Again';

  @override
  String get chatSuggestionNetWorth => 'What is my current net worth?';

  @override
  String get chatSuggestionSpending =>
      'How has my spending changed this month?';

  @override
  String get chatSuggestionSavings => 'How can I improve my savings rate?';

  @override
  String get chatSuggestionExpenses => 'What are my biggest expenses lately?';
}
