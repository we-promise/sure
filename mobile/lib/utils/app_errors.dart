import '../l10n/errors_en.dart';

/// User-friendly error message constants.
/// Use these instead of passing raw exception strings to the UI.
/// String text is defined in lib/l10n/errors_en.dart.
class AppErrors {
  AppErrors._();

  // Network
  static const String noInternet = ErrorStrings.noInternet;
  static const String requestTimeout = ErrorStrings.requestTimeout;
  static const String serverError = ErrorStrings.serverError;
  static const String secureConnectionFailed = ErrorStrings.secureConnectionFailed;
  static const String unexpected = ErrorStrings.unexpected;
  static const String networkError = ErrorStrings.networkError;

  // Auth
  static const String connectionFailed = ErrorStrings.connectionFailed;
  static const String sessionExpired = ErrorStrings.sessionExpired;
  static const String unauthorized = ErrorStrings.unauthorized;
  static const String tokenRefreshFailed = ErrorStrings.tokenRefreshFailed;
  static const String biometricFailed = ErrorStrings.biometricFailed;

  // Chat / AI
  static const String chatLoadFailed = ErrorStrings.chatLoadFailed;
  static const String chatListLoadFailed = ErrorStrings.chatListLoadFailed;
  static const String messageSendFailed = ErrorStrings.messageSendFailed;
  static const String aiResponseTimeout = ErrorStrings.aiResponseTimeout;
  static const String aiFeatureDisabled = ErrorStrings.aiFeatureDisabled;
  static const String chatCreateFailed = ErrorStrings.chatCreateFailed;
  static const String chatDeleteFailed = ErrorStrings.chatDeleteFailed;
  static const String chatUpdateFailed = ErrorStrings.chatUpdateFailed;

  // Accounts
  static const String accountsLoadFailed = ErrorStrings.accountsLoadFailed;
  static const String accountSyncFailed = ErrorStrings.accountSyncFailed;

  // Transactions
  static const String transactionSaveFailed = ErrorStrings.transactionSaveFailed;
  static const String transactionLoadFailed = ErrorStrings.transactionLoadFailed;
  static const String transactionDeleteFailed = ErrorStrings.transactionDeleteFailed;
  static const String transactionUpdateFailed = ErrorStrings.transactionUpdateFailed;
  static const String offlineEditNotAllowed = ErrorStrings.offlineEditNotAllowed;

  // Validation / Server
  static const String validationFailed = ErrorStrings.validationFailed;
  static const String rateLimited = ErrorStrings.rateLimited;
}
