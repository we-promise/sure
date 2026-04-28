class ErrorStrings {
  ErrorStrings._();

  // Network
  static const String noInternet = 'No internet connection. Please check your network and try again.';
  static const String requestTimeout = 'This is taking longer than expected. Please check your connection and try again.';
  static const String serverError = 'Something went wrong on our end. Please try again later.';
  static const String secureConnectionFailed = 'Secure connection failed. Please check your network and try again.';
  static const String unexpected = 'Something unexpected happened. Please try again.';
  static const String networkError = 'A network error occurred. Please check your connection and try again.';

  // Auth
  static const String connectionFailed = 'Unable to connect. Please check your network and try again.';
  static const String sessionExpired = 'Your session has expired. Please log in again.';
  static const String unauthorized = 'Your session has expired. Please log in again.';
  static const String tokenRefreshFailed = 'We couldn\'t refresh your session. Please log in again.';
  static const String biometricFailed = 'Biometric authentication failed. Please try again or use your password.';

  // Chat / AI
  static const String chatLoadFailed = 'We couldn\'t load this conversation. Please try again.';
  static const String chatListLoadFailed = 'We couldn\'t load your conversations. Please try again.';
  static const String messageSendFailed = 'Your message couldn\'t be sent. Please try again.';
  static const String aiResponseTimeout = 'The AI didn\'t respond in time. You can retry or start a new chat.';
  static const String aiFeatureDisabled = 'AI chat isn\'t enabled on your account yet. Contact support to get access.';
  static const String chatCreateFailed = 'We couldn\'t start a new conversation. Please try again.';
  static const String chatDeleteFailed = 'We couldn\'t delete this conversation. Please try again.';
  static const String chatUpdateFailed = 'We couldn\'t update this conversation. Please try again.';

  // Accounts
  static const String accountsLoadFailed = 'We couldn\'t load your accounts. Please try again.';
  static const String accountSyncFailed = 'We couldn\'t sync this account. Please try again.';

  // Transactions
  static const String transactionSaveFailed = 'We couldn\'t save your transaction. Please try again.';
  static const String transactionLoadFailed = 'We couldn\'t load your transactions. Please try again.';
  static const String transactionDeleteFailed = 'We couldn\'t delete this transaction. Please try again.';
  static const String transactionUpdateFailed = 'We couldn\'t update this transaction. Please try again.';
  static const String offlineEditNotAllowed = 'Editing isn\'t available while offline. Please reconnect and try again.';

  // Validation / Server
  static const String validationFailed = 'Please check your input and try again.';
  static const String rateLimited = 'Too many requests. Please wait a moment and try again.';
}
