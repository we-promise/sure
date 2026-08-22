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
  String get chatSuggestionNetWorth => 'What is my current net worth?';

  @override
  String get chatSuggestionSpending =>
      'How has my spending changed this month?';

  @override
  String get chatSuggestionSavings => 'How can I improve my savings rate?';

  @override
  String get chatSuggestionExpenses => 'What are my biggest expenses lately?';

  @override
  String get loginEmailLabel => 'Email';

  @override
  String get loginEmailRequired => 'Email is required';

  @override
  String get loginEmailInvalid => 'Please enter a valid email';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginPasswordRequired => 'Password is required';

  @override
  String get loginSignIn => 'Sign in';

  @override
  String get loginSignInWithGoogle => 'Sign in with Google';

  @override
  String get loginMfaLabel => 'Authentication Code';

  @override
  String get loginApiKeyLabel => 'API Key';

  @override
  String get navHome => 'Home';

  @override
  String get navIntro => 'Intro';

  @override
  String get navAssistant => 'Assistant';

  @override
  String get navMore => 'More';

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
  String get chatConversationNewTitle => 'New Conversation';

  @override
  String get chatConversationMessageHint => 'Ask anything about your finances…';

  @override
  String chatConversationGreetingWithName(String firstName) {
    return 'Hi $firstName, how can I help?';
  }

  @override
  String get chatConversationGreetingNoName => 'Hi there, how can I help?';

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
  String get transactionFormAmountRequired => 'Amount is required';

  @override
  String get transactionFormAmountInvalid => 'Please enter a valid amount';

  @override
  String get transactionFormDateLabel => 'Date';

  @override
  String get transactionFormNameLabel => 'Name';

  @override
  String get transactionFormCategoryLabel => 'Category';

  @override
  String get transactionEditTitle => 'Edit Transaction';

  @override
  String get transactionEditNameLabel => 'Name';

  @override
  String get transactionEditNameRequired => 'Name is required';

  @override
  String get transactionEditNotesLabel => 'Notes';

  @override
  String get transactionEditCategoryLabel => 'Category';

  @override
  String get transactionEditMerchantLabel => 'Merchant';

  @override
  String get transactionEditTagsLabel => 'Tags';

  @override
  String get transactionEditSaving => 'Saving…';

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
  String get transactionsListEmpty => 'No transactions';

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
      one: 'Deleted $count transaction',
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
  String get settingsProxyHeadersLabel => 'Custom Proxy Headers';

  @override
  String get settingsPrivacyHideAmountsLabel => 'Hide amounts';

  @override
  String get settingsPrivacyHideAmountsContent =>
      'Mask money values across the app';

  @override
  String get settingsBiometricLabel => 'Biometric Lock';

  @override
  String get settingsBiometricEnable => 'Enable biometric lock?';

  @override
  String get settingsBiometricEnableContent =>
      'Require biometric authentication when resuming the app.';

  @override
  String get settingsCheckForUpdates => 'Check for Updates';

  @override
  String get settingsUpdateAvailableTitle => 'Update Available';

  @override
  String settingsUpdateAvailableContent(String version) {
    return 'Version $version is available. Update now?';
  }

  @override
  String get settingsUpdateNewerVersionFallback => 'a newer version';

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
  String get settingsDeleteAccountTitle => 'Delete Account';

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
  String get ssoOnboardingFirstNameLabel => 'First Name';

  @override
  String get ssoOnboardingLastNameLabel => 'Last Name';

  @override
  String get ssoOnboardingLinkButton => 'Link Account';

  @override
  String get ssoOnboardingCreateButton => 'Create Account';

  @override
  String get ssoOnboardingAcceptInvitation => 'Accept Invitation';

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
  String get logViewerEmpty => 'No logs yet';

  @override
  String get connectivityOffline => 'You are offline';

  @override
  String connectivityPendingSync(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions pending sync',
      one: '$count transaction pending sync',
    );
    return '$_temp0';
  }

  @override
  String get connectivitySyncNow => 'Sync Now';

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
  String get accountDetailRecentBalanceHistory => 'Recent balance history';

  @override
  String get accountDetailTopHoldings => 'Top holdings';

  @override
  String get accountDetailHoldingFallback => 'Holding';

  @override
  String accountDetailCashChip(String amount) {
    return 'Cash $amount';
  }

  @override
  String get biometricLockFailedRetry =>
      'Authentication failed. Tap Unlock to try again.';

  @override
  String get settingsBiometricVerifyReason =>
      'Verify biometric to enable app lock';

  @override
  String get settingsBiometricFailed => 'Biometric authentication failed.';

  @override
  String get settingsUpdateOpenStoreError => 'Unable to open store link';

  @override
  String get settingsClearDataFailed => 'Failed to clear local data.';

  @override
  String get settingsClearDataSuccessDetailed =>
      'Local data cleared successfully. Pull to refresh to sync from server.';

  @override
  String get settingsContactOpenLinkError => 'Unable to open link';

  @override
  String get settingsResetAccountContent =>
      'Resetting your account will delete all your accounts, categories, merchants, tags, and other data, but keep your user account intact.\n\nThis action cannot be undone. Are you sure?';

  @override
  String get settingsResetAccount => 'Reset Account';

  @override
  String get settingsResetAccountInitiated =>
      'Account reset has been initiated. This may take a moment.';

  @override
  String get settingsResetAccountFailed => 'Failed to reset account';

  @override
  String get settingsDeleteAccountConfirmContent =>
      'Deleting your account will permanently remove all your data and cannot be undone.\n\nAre you sure you want to delete your account?';

  @override
  String get settingsDeleteAccountFailed => 'Failed to delete account';

  @override
  String get settingsProxyHeadersNote =>
      'Headers are sent by the app with API requests. External browser SSO pages may not receive them.';

  @override
  String get settingsProxyHeadersSaved => 'Custom proxy headers saved';

  @override
  String get settingsProxyHeadersSaveFailed =>
      'Failed to save custom proxy headers.';

  @override
  String settingsAppVersion(String version) {
    return 'App Version: $version';
  }

  @override
  String get settingsCheckForUpdatesSubtitle =>
      'See if a newer version is available';

  @override
  String get settingsContactUs => 'Contact us';

  @override
  String get settingsDebugLogsSemantics => 'Open debug logs';

  @override
  String get settingsDebugLogsSubtitle => 'View app diagnostic logs';

  @override
  String get settingsGroupByAccountType => 'Group by Account Type';

  @override
  String get settingsGroupByAccountTypeSubtitle =>
      'Group accounts by type (Crypto, Bank, etc.)';

  @override
  String get settingsProxyHeadersTileTitle => 'Custom proxy headers';

  @override
  String get settingsProxyHeadersTileSubtitleEmpty =>
      'Optional headers for a reverse proxy or auth gateway';

  @override
  String settingsProxyHeadersTileSubtitleCount(int count) {
    return '$count configured';
  }

  @override
  String get settingsClearDataTileSubtitle =>
      'Remove all cached transactions and accounts';

  @override
  String get settingsResetAccountTileSubtitle =>
      'Delete all accounts, categories, merchants, and tags but keep your user account';

  @override
  String get settingsDeleteAccountTileSubtitle =>
      'Permanently remove all your data. This cannot be undone.';

  @override
  String get settingsUserFallback => 'User';

  @override
  String chatListDeleteMultiContent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count chats? This cannot be undone.',
      one: 'Delete $count chat? This cannot be undone.',
    );
    return '$_temp0';
  }

  @override
  String get chatListDeletedSuccess => 'Chats deleted';

  @override
  String get chatListDeleteFailed => 'Failed to delete chats';

  @override
  String get chatListError => 'Failed to load chats';

  @override
  String get chatListJustNow => 'Just now';

  @override
  String chatListDeleteSingleContent(String title) {
    return 'Are you sure you want to delete \"$title\"?';
  }

  @override
  String get loginSignUpOpenError => 'Unable to open sign up page';

  @override
  String get loginApiKeyDialogTitle => 'API Key Login';

  @override
  String get loginApiKeyDialogBody => 'Enter your API key to sign in.';

  @override
  String get loginApiKeyInvalid => 'Invalid API key';

  @override
  String get loginApiKeySignIn => 'Sign In';

  @override
  String get loginDemoOrSignUpPrefix => 'Demo account or ';

  @override
  String get loginSignUpLink => 'Sign Up';

  @override
  String get loginSignUpSuffix => '!';

  @override
  String get loginMfaInfo =>
      'Two-factor authentication is enabled. Enter your code.';

  @override
  String get loginMfaCodeRequired => 'Please enter your authentication code';

  @override
  String get loginOrDivider => 'or';

  @override
  String get loginServerUrlHeading => 'Sure server URL:';

  @override
  String get loginApiKeyLoginButton => 'API-Key Login';

  @override
  String get loginBackendSettingsTooltip => 'Backend Settings';

  @override
  String get transactionEditSessionExpired =>
      'Session expired. Please login again.';

  @override
  String get transactionEditUpdated => 'Transaction updated';

  @override
  String get transactionEditUpdateFailed => 'Failed to update transaction';

  @override
  String transactionEditNameMaxLength(int max) {
    return 'Name must be $max characters or fewer';
  }

  @override
  String get transactionEditNameInvalidChars =>
      'Name contains unsupported characters';

  @override
  String transactionEditNotesMaxLength(int max) {
    return 'Notes must be $max characters or fewer';
  }

  @override
  String get transactionEditNotesInvalidChars =>
      'Notes contain unsupported characters';

  @override
  String get transactionEditNoCategory => 'No category';

  @override
  String get transactionEditCurrentCategory => 'Current category';

  @override
  String get transactionEditNoMerchant => 'No merchant';

  @override
  String get transactionEditCurrentMerchant => 'Current merchant';

  @override
  String get transactionEditNoTags => 'No tags available';

  @override
  String get transactionEditUnknownTag => 'Unknown tag';

  @override
  String get transactionEditSyncedOnly =>
      'Only synced transactions can be edited from mobile.';

  @override
  String get transactionEditCategoryHelper => 'Choose a replacement category';

  @override
  String get transactionEditMerchantHelper => 'Choose a replacement merchant';

  @override
  String get transactionFormSessionExpired =>
      'Session expired. Please login again.';

  @override
  String get transactionFormAmountRequiredPrompt => 'Please enter an amount';

  @override
  String get transactionFormAmountInvalidNumber =>
      'Please enter a valid number';

  @override
  String get transactionFormAmountTooSmall => 'Amount must be greater than 0';

  @override
  String get transactionFormCreateSuccessOnline =>
      'Transaction created successfully';

  @override
  String get transactionFormCreateSuccessOffline =>
      'Transaction saved (will sync when online)';

  @override
  String get transactionFormCreateFailed => 'Failed to create transaction';

  @override
  String transactionFormGenericError(String error) {
    return 'Error: $error';
  }

  @override
  String get transactionFormLess => 'Less';

  @override
  String get transactionFormMore => 'More';

  @override
  String get transactionFormDateHelper => 'Optional (default: today)';

  @override
  String get transactionFormNameHelper => 'Optional (default: SureApp)';

  @override
  String get transactionFormCategoryLoading => 'Loading categories…';

  @override
  String get transactionFormCategoryHelper => 'Optional';

  @override
  String get transactionFormNoCategory => 'No category';

  @override
  String get transactionFormCreateButton => 'Create Transaction';

  @override
  String get transactionFormAmountHelper => 'Required';

  @override
  String get logViewerClearConfirm =>
      'Are you sure you want to clear all logs?';

  @override
  String get logViewerClear => 'Clear';

  @override
  String get chatConversationEditTitle => 'Edit Title';

  @override
  String get chatConversationTitleLabel => 'Chat Title';

  @override
  String get chatConversationRefreshTooltip => 'Refresh';

  @override
  String get chatConversationLoadError => 'Failed to load chat';

  @override
  String get navEnableAiChatTitle => 'Turn on AI Chat?';

  @override
  String get navEnableAiChatContent =>
      'AI Chat is currently disabled in your account settings. Would you like to turn it on now?';

  @override
  String get navEnableAiChatNotNow => 'Not now';

  @override
  String get navEnableAiChatConfirm => 'Turn on AI';

  @override
  String get navEnableAiChatFailed => 'Unable to enable AI right now.';

  @override
  String get transactionsListEditTooltip => 'Edit transaction';

  @override
  String get connectivitySignInToSync => 'Please sign in to sync transactions';

  @override
  String get connectivitySyncSuccess => 'Transactions synced successfully';

  @override
  String get connectivitySyncFailed =>
      'Failed to sync transactions. Please try again.';

  @override
  String get connectivityAuthFailed =>
      'Unable to authenticate. Please try again.';

  @override
  String ssoOnboardingSignedInAs(String email) {
    return 'Signed in as $email';
  }

  @override
  String get ssoOnboardingGoogleVerified => 'Google account verified';

  @override
  String get ssoOnboardingLinkCredentialsNote =>
      'Enter your existing account credentials to link with Google Sign-In.';

  @override
  String get ssoOnboardingPendingInvitationNote =>
      'You have a pending invitation. Accept it to join an existing household.';

  @override
  String get ssoOnboardingCreateIdentityNote =>
      'Create a new account using your Google identity.';

  @override
  String get ssoOnboardingFirstNameRequired => 'First name is required';

  @override
  String get ssoOnboardingLastNameRequired => 'Last name is required';

  @override
  String get backendConfigTimeout =>
      'Connection timeout. Please check the URL and try again.';

  @override
  String get backendConfigSuccess => 'Connection successful!';

  @override
  String backendConfigServerError(int code) {
    return 'Server responded with status $code. Please check if this is a Sure backend server.';
  }

  @override
  String backendConfigConnectionFailed(String error) {
    return 'Connection failed: $error';
  }

  @override
  String backendConfigSaveFailed(String error) {
    return 'Failed to save URL: $error';
  }

  @override
  String get backendConfigUrlRequired => 'Please enter a backend URL';

  @override
  String get backendConfigUrlScheme =>
      'URL must start with http:// or https://';

  @override
  String get backendConfigUrlInvalid => 'Please enter a valid URL';

  @override
  String get backendConfigHeadersHelp =>
      'Headers are sent by the app with API requests. External browser SSO pages may not receive them.';

  @override
  String get recentTransactionsUnknownAccount => 'Unknown Account';

  @override
  String get accountDetailUnavailable =>
      'Account details are temporarily unavailable';

  @override
  String chatListMinutesAgo(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String chatListHoursAgo(int hours) {
    return '${hours}h ago';
  }

  @override
  String chatListDaysAgo(int days) {
    return '${days}d ago';
  }

  @override
  String get chatConversationStartFailed =>
      'Failed to start conversation. Please try again.';
}
