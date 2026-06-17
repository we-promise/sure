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
  String get commonDelete => 'Delete';

  @override
  String get commonAll => 'All';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonClose => 'Close';

  @override
  String get commonUndo => 'Undo';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonError => 'Something went wrong';

  @override
  String get commonNoData => 'No data available';

  @override
  String get chatSuggestionNetWorth => 'What is my current net worth?';

  @override
  String get chatSuggestionSpending =>
      'How has my spending changed this month?';

  @override
  String get chatSuggestionSavings => 'How can I improve my savings rate?';

  @override
  String get chatSuggestionExpenses => 'What are my biggest expenses lately?';

  @override
  String get loginTitle => 'Sure Finances';

  @override
  String get loginEmailLabel => 'Email';

  @override
  String get loginEmailHint => 'Enter your email';

  @override
  String get loginEmailRequired => 'Email is required';

  @override
  String get loginEmailInvalid => 'Please enter a valid email';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginPasswordHint => 'Enter your password';

  @override
  String get loginPasswordRequired => 'Password is required';

  @override
  String get loginSignIn => 'Sign in';

  @override
  String get loginSignInWithGoogle => 'Sign in with Google';

  @override
  String get loginMfaTitle => 'Two-Factor Authentication';

  @override
  String get loginMfaContent =>
      'Enter the 6-digit code from your authenticator app.';

  @override
  String get loginMfaLabel => 'Authentication Code';

  @override
  String get loginMfaHint => 'Enter 6-digit code';

  @override
  String get loginMfaVerify => 'Verify';

  @override
  String get loginApiKeyTitle => 'Enter API Key';

  @override
  String get loginApiKeyLabel => 'API Key';

  @override
  String get loginApiKeyHint => 'Paste your API key';

  @override
  String get loginApiKeySubmit => 'Submit';

  @override
  String get loginServerUrlLabel => 'Server URL';

  @override
  String get navHome => 'Home';

  @override
  String get navIntro => 'Intro';

  @override
  String get navAssistant => 'Assistant';

  @override
  String get navMore => 'More';

  @override
  String get navEnableAiTitle => 'Enable AI Assistant';

  @override
  String get navEnableAiContent =>
      'The AI assistant requires an OpenAI API key configured in your Sure settings. Would you like to go to settings?';

  @override
  String get navEnableAiGoToSettings => 'Go to Settings';

  @override
  String get dashboardSyncError => 'Sync failed';

  @override
  String get dashboardSyncFailed => 'Sync failed. Please try again.';

  @override
  String get dashboardRefreshing => 'Refreshing accounts…';

  @override
  String get dashboardAccountsUpdated => 'Accounts updated';

  @override
  String get dashboardSyncing => 'Syncing data from server…';

  @override
  String get dashboardSynced => 'Synced';

  @override
  String get dashboardSyncAll => 'Sync All';

  @override
  String get dashboardErrorLoadingAccounts => 'Failed to load accounts';

  @override
  String get dashboardNoAccounts => 'No accounts yet';

  @override
  String get dashboardNoAccountsSubtitle =>
      'Add accounts in the web app to see them here.';

  @override
  String get dashboardFilterEmpty => 'No accounts match the current filter';

  @override
  String get chatListTitle => 'Chats';

  @override
  String get chatListNewChat => 'New chat';

  @override
  String get chatListEmpty => 'No chats yet';

  @override
  String get chatListEmptySubtitle =>
      'Start a conversation with your AI assistant';

  @override
  String get chatListDeleteTitle => 'Delete Chat';

  @override
  String get chatListDeleteContent =>
      'Are you sure you want to delete this chat?';

  @override
  String get chatConversationNewTitle => 'New Conversation';

  @override
  String get chatConversationMessageHint => 'Ask anything about your finances…';

  @override
  String get chatConversationEditTitleHint => 'Conversation title';

  @override
  String get chatConversationRenameTitle => 'Rename Conversation';

  @override
  String get chatConversationRename => 'Rename';

  @override
  String chatConversationGreetingWithName(String firstName) {
    return 'Hi $firstName, how can I help?';
  }

  @override
  String get chatConversationGreetingNoName => 'Hi there, how can I help?';

  @override
  String get chatConversationError => 'Failed to send message';

  @override
  String get transactionFormNewTitle => 'New Transaction';

  @override
  String get transactionFormTypeLabel => 'Type';

  @override
  String get transactionFormTypeExpense => 'Expense';

  @override
  String get transactionFormTypeIncome => 'Income';

  @override
  String get transactionFormAmountLabel => 'Amount';

  @override
  String get transactionFormAmountHint => '0.00';

  @override
  String get transactionFormAmountRequired => 'Amount is required';

  @override
  String get transactionFormAmountInvalid => 'Please enter a valid amount';

  @override
  String get transactionFormDateLabel => 'Date';

  @override
  String get transactionFormNameLabel => 'Name';

  @override
  String get transactionFormNameHint => 'Transaction name';

  @override
  String get transactionFormNameRequired => 'Name is required';

  @override
  String get transactionFormCategoryLabel => 'Category';

  @override
  String get transactionFormSaveSuccess => 'Transaction saved';

  @override
  String get transactionFormSaveError => 'Failed to save transaction';

  @override
  String get transactionEditTitle => 'Edit Transaction';

  @override
  String get transactionEditNameLabel => 'Name';

  @override
  String get transactionEditNameHint => 'Transaction name';

  @override
  String get transactionEditNameRequired => 'Name is required';

  @override
  String get transactionEditNotesLabel => 'Notes';

  @override
  String get transactionEditNotesHint => 'Add a note';

  @override
  String get transactionEditCategoryLabel => 'Category';

  @override
  String get transactionEditMerchantLabel => 'Merchant';

  @override
  String get transactionEditMerchantHint => 'Search merchants';

  @override
  String get transactionEditTagsLabel => 'Tags';

  @override
  String get transactionEditTagsHint => 'Add tags';

  @override
  String get transactionEditSaving => 'Saving…';

  @override
  String get transactionEditSaveError => 'Failed to save changes';

  @override
  String get transactionsListDeleteTitle => 'Delete Transaction';

  @override
  String transactionsListDeleteSingleContent(String name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String get transactionsListDeleteMultiTitle => 'Delete Transactions';

  @override
  String get transactionsListDeleteMultiContent =>
      'Are you sure you want to delete the selected transactions?';

  @override
  String get transactionsListDeleteUndoMessage => 'Transaction deleted';

  @override
  String get transactionsListUndoAction => 'Undo';

  @override
  String get transactionsListEmpty => 'No transactions';

  @override
  String get transactionsListEmptySubtitle =>
      'Transactions will appear here once synced';

  @override
  String get transactionsListAuthFailed =>
      'Authentication failed: Please log in again';

  @override
  String get transactionsListNoTransactionsYet => 'No transactions yet';

  @override
  String get transactionsListEmptyAddFirst =>
      'Tap + to add your first transaction';

  @override
  String get transactionsListNoCategoryMatch =>
      'No transactions match this category';

  @override
  String get transactionsListRetry => 'Retry';

  @override
  String get transactionsListDeletedSuccess => 'Transaction deleted';

  @override
  String get transactionsListSingleDeleteFailed =>
      'Failed to delete transaction';

  @override
  String transactionsListDeletedMulti(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Deleted $count transactions',
      one: 'Deleted 1 transaction',
    );
    return '$_temp0';
  }

  @override
  String get transactionsListDeleteFailed => 'Failed to delete transactions';

  @override
  String get transactionsListDeleteNoToken =>
      'Failed to delete: No access token';

  @override
  String get transactionsListUndoTitle => 'Undo Transaction';

  @override
  String get transactionsListUndoRemovePending =>
      'Remove this pending transaction?';

  @override
  String get transactionsListUndoRestoreConfirm => 'Restore this transaction?';

  @override
  String get transactionsListUndoPendingRemoved =>
      'Pending transaction removed';

  @override
  String get transactionsListUndoRestored => 'Transaction restored';

  @override
  String get transactionsListUndoFailed => 'Failed to undo transaction';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionDisplay => 'Display';

  @override
  String get settingsSectionConnection => 'Connection';

  @override
  String get settingsSectionDataManagement => 'Data Management';

  @override
  String get settingsSectionSecurity => 'Security';

  @override
  String get settingsSectionDangerZone => 'Danger Zone';

  @override
  String get settingsThemeLabel => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsServerUrlLabel => 'Server URL';

  @override
  String get settingsChangeServer => 'Change Server';

  @override
  String get settingsProxyHeadersLabel => 'Custom Proxy Headers';

  @override
  String get settingsBiometricLabel => 'Biometric Lock';

  @override
  String get settingsBiometricEnable => 'Enable biometric lock?';

  @override
  String get settingsBiometricEnableContent =>
      'Require biometric authentication when resuming the app.';

  @override
  String get settingsBiometricEnable2 => 'Enable';

  @override
  String get settingsBiometricDisable => 'Disable biometric lock?';

  @override
  String get settingsBiometricDisableContent =>
      'Biometric authentication will no longer be required.';

  @override
  String get settingsBiometricDisable2 => 'Disable';

  @override
  String get settingsBiometricNotAvailable =>
      'Biometric authentication is not available on this device.';

  @override
  String get settingsCheckForUpdates => 'Check for Updates';

  @override
  String get settingsUpdateAvailableTitle => 'Update Available';

  @override
  String settingsUpdateAvailableContent(String version) {
    return 'Version $version is available. Update now?';
  }

  @override
  String get settingsUpdateNow => 'Update Now';

  @override
  String get settingsNoUpdateAvailable => 'You\'re on the latest version.';

  @override
  String get settingsUpdateError => 'Could not check for updates.';

  @override
  String get settingsClearDataTitle => 'Clear All Data';

  @override
  String get settingsClearDataContent =>
      'This will remove all locally cached data. Your data on the server will not be affected.';

  @override
  String get settingsClearData => 'Clear Data';

  @override
  String get settingsClearDataSuccess => 'Local data cleared';

  @override
  String get settingsResetAppTitle => 'Reset Application';

  @override
  String get settingsResetAppContent =>
      'This will sign you out and clear all local data. Your data on the server will not be affected.';

  @override
  String get settingsResetApp => 'Reset';

  @override
  String get settingsDeleteAccountTitle => 'Delete Account';

  @override
  String get settingsDeleteAccountContent =>
      'This will permanently delete your account and all associated data. This action cannot be undone.';

  @override
  String get settingsDeleteAccount => 'Delete Account';

  @override
  String get settingsSignOutTitle => 'Sign Out';

  @override
  String get settingsSignOutContent => 'Are you sure you want to sign out?';

  @override
  String get settingsSignOut => 'Sign Out';

  @override
  String get settingsDebugLogs => 'Debug Logs';

  @override
  String get ssoOnboardingTitle => 'Link Your Account';

  @override
  String get ssoOnboardingTabLink => 'Link existing';

  @override
  String get ssoOnboardingTabCreate => 'Create new';

  @override
  String get ssoOnboardingLinkNote =>
      'Link your SSO identity to an existing Sure account using your email and password.';

  @override
  String get ssoOnboardingCreateNote =>
      'Create a new Sure account linked to your SSO identity.';

  @override
  String get ssoOnboardingFirstNameLabel => 'First Name';

  @override
  String get ssoOnboardingLastNameLabel => 'Last Name';

  @override
  String get ssoOnboardingLinkButton => 'Link Account';

  @override
  String get ssoOnboardingCreateButton => 'Create Account';

  @override
  String get ssoOnboardingAcceptTerms => 'I accept the Terms of Service';

  @override
  String get calendarTitle => 'Account Calendar';

  @override
  String get calendarAccountTypeSection => 'Account Type';

  @override
  String get calendarSegmentAssets => 'Assets';

  @override
  String get calendarSegmentLiabilities => 'Liabilities';

  @override
  String get calendarSelectAccount => 'Select Account';

  @override
  String get calendarMonthlyChange => 'Monthly Change';

  @override
  String get calendarNoTransactions => 'No transactions on this day';

  @override
  String get moreCalendar => 'Account Calendar';

  @override
  String get moreCalendarSubtitle => 'View monthly balance changes by account';

  @override
  String get moreRecentTransactions => 'Recent Transactions';

  @override
  String get moreRecentTransactionsSubtitle =>
      'View recent transactions across all accounts';

  @override
  String get biometricTitle => 'App Locked';

  @override
  String get biometricSubtitle => 'Authenticate to continue';

  @override
  String get biometricUnlock => 'Unlock';

  @override
  String get biometricAuthenticating => 'Authenticating…';

  @override
  String get biometricLogOut => 'Log out';

  @override
  String get backendConfigTitle => 'Configuration';

  @override
  String get backendConfigSubtitle => 'Update your Sure server URL';

  @override
  String get backendConfigExampleUrlsLabel => 'Example URLs';

  @override
  String get backendConfigUrlLabel => 'Sure server URL';

  @override
  String get backendConfigUrlHint => 'https://app.sure.am';

  @override
  String get backendConfigProxyHeadersLabel => 'Custom proxy headers';

  @override
  String get backendConfigProxyHeadersSubtitle =>
      'Optional headers for a reverse proxy or auth gateway';

  @override
  String backendConfigProxyHeadersCount(int count) {
    return '$count configured';
  }

  @override
  String get backendConfigTesting => 'Testing…';

  @override
  String get backendConfigTestButton => 'Test Connection';

  @override
  String get backendConfigContinueButton => 'Continue';

  @override
  String get backendConfigChangeHint =>
      'You can change this later in the settings.';

  @override
  String get recentTransactionsTitle => 'Recent Transactions';

  @override
  String get recentTransactionsEmpty => 'No Transactions';

  @override
  String get recentTransactionsDisplayLimit => 'Display Limit';

  @override
  String recentTransactionsShowN(int count) {
    return 'Show $count';
  }

  @override
  String get recentTransactionsPullToRefresh => 'Pull to refresh';

  @override
  String get logViewerTitle => 'Debug Logs';

  @override
  String get logViewerFilterAll => 'All';

  @override
  String get logViewerFilterInfo => 'Info';

  @override
  String get logViewerFilterWarning => 'Warning';

  @override
  String get logViewerFilterError => 'Error';

  @override
  String get logViewerFilterDebug => 'Debug';

  @override
  String get logViewerAutoScrollEnable => 'Enable auto-scroll';

  @override
  String get logViewerAutoScrollDisable => 'Disable auto-scroll';

  @override
  String get logViewerCopyLogs => 'Copy logs';

  @override
  String get logViewerClearLogs => 'Clear logs';

  @override
  String get logViewerLogsCopied => 'Logs copied to clipboard';

  @override
  String get logViewerLogsCleared => 'Logs cleared';

  @override
  String get logViewerEmpty => 'No logs to display';

  @override
  String get connectivityOffline => 'You are offline';

  @override
  String connectivityPendingSync(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions pending sync',
      one: '1 transaction pending sync',
    );
    return '$_temp0';
  }

  @override
  String get connectivitySyncNow => 'Sync Now';

  @override
  String get connectivityAuthError =>
      'Authentication error — please sign in again.';

  @override
  String get connectivitySyncError => 'Sync failed — tap to retry.';

  @override
  String get proxyHeadersAddHeader => 'Add header';

  @override
  String get proxyHeadersNameLabel => 'Header name';

  @override
  String get proxyHeadersNameHint => 'X-Auth-Token';

  @override
  String get proxyHeadersValueLabel => 'Header value';

  @override
  String get proxyHeadersRemove => 'Remove header';

  @override
  String get accountDetailRefreshTooltip => 'Refresh account details';

  @override
  String get accountDetailError => 'Could not load account details';

  @override
  String get accountDetailRecentBalanceHistory => 'Recent balance history';

  @override
  String get accountDetailTopHoldings => 'Top holdings';

  @override
  String get accountDetailHoldingFallback => 'Holding';

  @override
  String accountDetailCashChip(String amount) {
    return 'Cash $amount';
  }
}
