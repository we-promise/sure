import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Application title shown in the OS task switcher.
  ///
  /// In en, this message translates to:
  /// **'Sure Finances'**
  String get appTitle;

  /// Generic cancel action label.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Generic save/confirm action label.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// Generic retry action label.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get commonTryAgain;

  /// Generic delete action label.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// Label for the 'All' filter chip (currency filter, category filter, etc.).
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get commonAll;

  /// Generic refresh action label.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get commonRefresh;

  /// Generic close/dismiss action label.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// Generic undo action label.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get commonUndo;

  /// Suggested chat prompt on the empty assistant screen.
  ///
  /// In en, this message translates to:
  /// **'What is my current net worth?'**
  String get chatSuggestionNetWorth;

  /// Suggested chat prompt on the empty assistant screen.
  ///
  /// In en, this message translates to:
  /// **'How has my spending changed this month?'**
  String get chatSuggestionSpending;

  /// Suggested chat prompt on the empty assistant screen.
  ///
  /// In en, this message translates to:
  /// **'How can I improve my savings rate?'**
  String get chatSuggestionSavings;

  /// Suggested chat prompt on the empty assistant screen.
  ///
  /// In en, this message translates to:
  /// **'What are my biggest expenses lately?'**
  String get chatSuggestionExpenses;

  /// Label for the email text field on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get loginEmailLabel;

  /// Validation error when email field is empty.
  ///
  /// In en, this message translates to:
  /// **'Email is required'**
  String get loginEmailRequired;

  /// Validation error when email format is invalid.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid email'**
  String get loginEmailInvalid;

  /// Label for the password field on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPasswordLabel;

  /// Validation error when password field is empty.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get loginPasswordRequired;

  /// Primary sign-in button label.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginSignIn;

  /// Google SSO button label.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get loginSignInWithGoogle;

  /// Label for the MFA code input field.
  ///
  /// In en, this message translates to:
  /// **'Authentication Code'**
  String get loginMfaLabel;

  /// Label for the API key input field.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get loginApiKeyLabel;

  /// Bottom navigation label for the Home (dashboard) tab.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// Bottom navigation label for the Intro tab.
  ///
  /// In en, this message translates to:
  /// **'Intro'**
  String get navIntro;

  /// Bottom navigation label for the AI assistant tab.
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get navAssistant;

  /// Bottom navigation label for the More tab.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get navMore;

  /// Snackbar message when a sync attempt fails.
  ///
  /// In en, this message translates to:
  /// **'Sync failed'**
  String get dashboardSyncError;

  /// Snackbar message when a sync attempt fails with retry instruction.
  ///
  /// In en, this message translates to:
  /// **'Sync failed. Please try again.'**
  String get dashboardSyncFailed;

  /// Snackbar message while accounts are being refreshed after a transaction.
  ///
  /// In en, this message translates to:
  /// **'Refreshing accounts…'**
  String get dashboardRefreshing;

  /// Snackbar message shown after accounts refresh completes.
  ///
  /// In en, this message translates to:
  /// **'Accounts updated'**
  String get dashboardAccountsUpdated;

  /// Snackbar message while sync is in progress.
  ///
  /// In en, this message translates to:
  /// **'Syncing data from server…'**
  String get dashboardSyncing;

  /// Label shown in the sync status indicator after a successful sync.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get dashboardSynced;

  /// Error state message when accounts fail to load.
  ///
  /// In en, this message translates to:
  /// **'Failed to load accounts'**
  String get dashboardErrorLoadingAccounts;

  /// Empty state message when no accounts exist.
  ///
  /// In en, this message translates to:
  /// **'No accounts yet'**
  String get dashboardNoAccounts;

  /// Empty state subtitle when no accounts exist.
  ///
  /// In en, this message translates to:
  /// **'Add accounts in the web app to see them here.'**
  String get dashboardNoAccountsSubtitle;

  /// Empty state when the active account filter returns no results.
  ///
  /// In en, this message translates to:
  /// **'No accounts match the current filter'**
  String get dashboardFilterEmpty;

  /// Title for the chat list screen / app bar.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatListTitle;

  /// FAB tooltip for creating a new chat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get chatListNewChat;

  /// Empty-state heading on the chat list screen.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get chatListEmpty;

  /// Empty-state subtitle on the chat list screen.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation with your AI assistant'**
  String get chatListEmptySubtitle;

  /// Title for the delete-chat confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Chat'**
  String get chatListDeleteTitle;

  /// Placeholder title for a new conversation before it is saved.
  ///
  /// In en, this message translates to:
  /// **'New Conversation'**
  String get chatConversationNewTitle;

  /// Hint text inside the chat message input field.
  ///
  /// In en, this message translates to:
  /// **'Ask anything about your finances…'**
  String get chatConversationMessageHint;

  /// Greeting shown in a new conversation when the user's first name is known.
  ///
  /// In en, this message translates to:
  /// **'Hi {firstName}, how can I help?'**
  String chatConversationGreetingWithName(String firstName);

  /// Greeting shown in a new conversation when the user's first name is not available.
  ///
  /// In en, this message translates to:
  /// **'Hi there, how can I help?'**
  String get chatConversationGreetingNoName;

  /// App bar title for the new-transaction form.
  ///
  /// In en, this message translates to:
  /// **'New Transaction'**
  String get transactionFormNewTitle;

  /// Label for the transaction type segmented control.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get transactionFormTypeLabel;

  /// Segment label for an expense transaction.
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get transactionFormTypeExpense;

  /// Segment label for an income transaction.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get transactionFormTypeIncome;

  /// Label for the amount input field.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get transactionFormAmountLabel;

  /// Validation error when amount is empty.
  ///
  /// In en, this message translates to:
  /// **'Amount is required'**
  String get transactionFormAmountRequired;

  /// Validation error when amount is not a number.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid amount'**
  String get transactionFormAmountInvalid;

  /// Label for the date picker field.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get transactionFormDateLabel;

  /// Label for the transaction name/payee field.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get transactionFormNameLabel;

  /// Label for the category picker field.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get transactionFormCategoryLabel;

  /// App bar title for the edit-transaction screen.
  ///
  /// In en, this message translates to:
  /// **'Edit Transaction'**
  String get transactionEditTitle;

  /// Label for the name field in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get transactionEditNameLabel;

  /// Validation error when name is empty in edit form.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get transactionEditNameRequired;

  /// Label for the notes field in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get transactionEditNotesLabel;

  /// Label for the category field in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get transactionEditCategoryLabel;

  /// Label for the merchant field in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Merchant'**
  String get transactionEditMerchantLabel;

  /// Label for the tags field in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get transactionEditTagsLabel;

  /// In-progress label shown on the save button while saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get transactionEditSaving;

  /// Title for the single-transaction delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Transaction'**
  String get transactionsListDeleteTitle;

  /// Body of the delete confirmation dialog for a named transaction.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"?'**
  String transactionsListDeleteSingleContent(String name);

  /// Title for the multi-transaction delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Transactions'**
  String get transactionsListDeleteMultiTitle;

  /// Body of the multi-transaction delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the selected transactions?'**
  String get transactionsListDeleteMultiContent;

  /// Empty-state message when no transactions exist.
  ///
  /// In en, this message translates to:
  /// **'No transactions'**
  String get transactionsListEmpty;

  /// Snackbar message when the API returns an auth failure.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed: Please log in again'**
  String get transactionsListAuthFailed;

  /// Empty-state heading when an account has no transactions.
  ///
  /// In en, this message translates to:
  /// **'No transactions yet'**
  String get transactionsListNoTransactionsYet;

  /// Empty-state subtitle prompting the user to add their first transaction.
  ///
  /// In en, this message translates to:
  /// **'Tap + to add your first transaction'**
  String get transactionsListEmptyAddFirst;

  /// Empty state shown when category filter returns no transactions.
  ///
  /// In en, this message translates to:
  /// **'No transactions match this category'**
  String get transactionsListNoCategoryMatch;

  /// Button label on the transactions error state.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get transactionsListRetry;

  /// Snackbar after a single transaction is deleted.
  ///
  /// In en, this message translates to:
  /// **'Transaction deleted'**
  String get transactionsListDeletedSuccess;

  /// Snackbar when deleting a single transaction fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete transaction'**
  String get transactionsListSingleDeleteFailed;

  /// Snackbar message after multiple transactions are deleted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Deleted {count} transaction} other{Deleted {count} transactions}}'**
  String transactionsListDeletedMulti(int count);

  /// Snackbar when multi-delete fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete transactions'**
  String get transactionsListDeleteFailed;

  /// Snackbar when delete fails due to missing token.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete: No access token'**
  String get transactionsListDeleteNoToken;

  /// Title for the undo-transaction dialog.
  ///
  /// In en, this message translates to:
  /// **'Undo Transaction'**
  String get transactionsListUndoTitle;

  /// Confirmation question for removing a pending transaction.
  ///
  /// In en, this message translates to:
  /// **'Remove this pending transaction?'**
  String get transactionsListUndoRemovePending;

  /// Confirmation question for restoring a transaction.
  ///
  /// In en, this message translates to:
  /// **'Restore this transaction?'**
  String get transactionsListUndoRestoreConfirm;

  /// Snackbar after a pending transaction is removed.
  ///
  /// In en, this message translates to:
  /// **'Pending transaction removed'**
  String get transactionsListUndoPendingRemoved;

  /// Snackbar after a transaction is restored.
  ///
  /// In en, this message translates to:
  /// **'Transaction restored'**
  String get transactionsListUndoRestored;

  /// Snackbar when undoing a transaction fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to undo transaction'**
  String get transactionsListUndoFailed;

  /// Settings section header for display/appearance options.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get settingsSectionDisplay;

  /// Settings section header for server/connection options.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsSectionConnection;

  /// Settings section header for data import/export options.
  ///
  /// In en, this message translates to:
  /// **'Data Management'**
  String get settingsSectionDataManagement;

  /// Settings section header for security options.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get settingsSectionSecurity;

  /// Settings section header for destructive actions.
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get settingsSectionDangerZone;

  /// Label for the theme picker setting.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsThemeLabel;

  /// Theme option: follow system setting.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// Theme option: light mode.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// Theme option: dark mode.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// Label for the custom proxy headers setting.
  ///
  /// In en, this message translates to:
  /// **'Custom Proxy Headers'**
  String get settingsProxyHeadersLabel;

  /// Label for the toggle that masks monetary amounts across the app.
  ///
  /// In en, this message translates to:
  /// **'Hide amounts'**
  String get settingsPrivacyHideAmountsLabel;

  /// Subtitle describing the hide-amounts toggle.
  ///
  /// In en, this message translates to:
  /// **'Mask money values across the app'**
  String get settingsPrivacyHideAmountsContent;

  /// Label for the biometric lock toggle.
  ///
  /// In en, this message translates to:
  /// **'Biometric Lock'**
  String get settingsBiometricLabel;

  /// Title of the dialog to enable biometric lock.
  ///
  /// In en, this message translates to:
  /// **'Enable biometric lock?'**
  String get settingsBiometricEnable;

  /// Body text of the enable-biometric dialog.
  ///
  /// In en, this message translates to:
  /// **'Require biometric authentication when resuming the app.'**
  String get settingsBiometricEnableContent;

  /// Label for the check-for-updates action.
  ///
  /// In en, this message translates to:
  /// **'Check for Updates'**
  String get settingsCheckForUpdates;

  /// Title for the update-available dialog.
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
  String get settingsUpdateAvailableTitle;

  /// Body text for the update-available dialog.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available. Update now?'**
  String settingsUpdateAvailableContent(String version);

  /// Fallback used in the update-available dialog when the store version number is unknown (e.g. 'Version a newer version is available').
  ///
  /// In en, this message translates to:
  /// **'a newer version'**
  String get settingsUpdateNewerVersionFallback;

  /// Confirm button in the update-available dialog.
  ///
  /// In en, this message translates to:
  /// **'Update Now'**
  String get settingsUpdateNow;

  /// Snackbar when no update is available.
  ///
  /// In en, this message translates to:
  /// **'You\'re on the latest version.'**
  String get settingsNoUpdateAvailable;

  /// Snackbar when the update check fails.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates.'**
  String get settingsUpdateError;

  /// Title for the clear-all-data confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Clear All Data'**
  String get settingsClearDataTitle;

  /// Body text for the clear-all-data dialog.
  ///
  /// In en, this message translates to:
  /// **'This will remove all locally cached data. Your data on the server will not be affected.'**
  String get settingsClearDataContent;

  /// Confirm button in the clear-data dialog.
  ///
  /// In en, this message translates to:
  /// **'Clear Data'**
  String get settingsClearData;

  /// Snackbar after local data is cleared.
  ///
  /// In en, this message translates to:
  /// **'Local data cleared'**
  String get settingsClearDataSuccess;

  /// Title for the delete-account confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get settingsDeleteAccountTitle;

  /// Confirm button in the delete-account dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get settingsDeleteAccount;

  /// Title for the sign-out confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get settingsSignOutTitle;

  /// Body text for the sign-out dialog.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?'**
  String get settingsSignOutContent;

  /// Confirm button in the sign-out dialog and settings list tile label.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get settingsSignOut;

  /// Label for the debug logs navigation tile.
  ///
  /// In en, this message translates to:
  /// **'Debug Logs'**
  String get settingsDebugLogs;

  /// App bar title for the SSO onboarding screen.
  ///
  /// In en, this message translates to:
  /// **'Link Your Account'**
  String get ssoOnboardingTitle;

  /// Tab label for linking an existing Sure account via SSO.
  ///
  /// In en, this message translates to:
  /// **'Link existing'**
  String get ssoOnboardingTabLink;

  /// Tab label for creating a new Sure account via SSO.
  ///
  /// In en, this message translates to:
  /// **'Create new'**
  String get ssoOnboardingTabCreate;

  /// Label for the first-name field on the SSO onboarding screen.
  ///
  /// In en, this message translates to:
  /// **'First Name'**
  String get ssoOnboardingFirstNameLabel;

  /// Label for the last-name field on the SSO onboarding screen.
  ///
  /// In en, this message translates to:
  /// **'Last Name'**
  String get ssoOnboardingLastNameLabel;

  /// Button label to link an existing account.
  ///
  /// In en, this message translates to:
  /// **'Link Account'**
  String get ssoOnboardingLinkButton;

  /// Button label to create a new account.
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get ssoOnboardingCreateButton;

  /// Tab and submit button label when the user has a pending household invitation to accept.
  ///
  /// In en, this message translates to:
  /// **'Accept Invitation'**
  String get ssoOnboardingAcceptInvitation;

  /// App bar title for the account calendar screen.
  ///
  /// In en, this message translates to:
  /// **'Account Calendar'**
  String get calendarTitle;

  /// Section header for the account-type selector on the calendar screen.
  ///
  /// In en, this message translates to:
  /// **'Account Type'**
  String get calendarAccountTypeSection;

  /// Segment label for asset-type accounts on the calendar.
  ///
  /// In en, this message translates to:
  /// **'Assets'**
  String get calendarSegmentAssets;

  /// Segment label for liability-type accounts on the calendar.
  ///
  /// In en, this message translates to:
  /// **'Liabilities'**
  String get calendarSegmentLiabilities;

  /// Placeholder shown in the account dropdown when none is selected.
  ///
  /// In en, this message translates to:
  /// **'Select Account'**
  String get calendarSelectAccount;

  /// Label for the monthly-change metric on the calendar screen.
  ///
  /// In en, this message translates to:
  /// **'Monthly Change'**
  String get calendarMonthlyChange;

  /// Empty-state message when no transactions exist for the selected day.
  ///
  /// In en, this message translates to:
  /// **'No transactions on this day'**
  String get calendarNoTransactions;

  /// Menu item title for Account Calendar in the More screen.
  ///
  /// In en, this message translates to:
  /// **'Account Calendar'**
  String get moreCalendar;

  /// Subtitle for the Account Calendar menu item in the More screen.
  ///
  /// In en, this message translates to:
  /// **'View monthly balance changes by account'**
  String get moreCalendarSubtitle;

  /// Menu item title for Recent Transactions in the More screen.
  ///
  /// In en, this message translates to:
  /// **'Recent Transactions'**
  String get moreRecentTransactions;

  /// Subtitle for the Recent Transactions menu item.
  ///
  /// In en, this message translates to:
  /// **'View recent transactions across all accounts'**
  String get moreRecentTransactionsSubtitle;

  /// Heading shown on the biometric lock screen.
  ///
  /// In en, this message translates to:
  /// **'App Locked'**
  String get biometricTitle;

  /// Subtitle shown on the biometric lock screen.
  ///
  /// In en, this message translates to:
  /// **'Authenticate to continue'**
  String get biometricSubtitle;

  /// Button label when biometric prompt is ready.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get biometricUnlock;

  /// Button label while the biometric prompt is in progress.
  ///
  /// In en, this message translates to:
  /// **'Authenticating…'**
  String get biometricAuthenticating;

  /// Button to log out from the biometric lock screen.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get biometricLogOut;

  /// Headline on the backend configuration screen.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get backendConfigTitle;

  /// Subtitle below the headline on the backend configuration screen.
  ///
  /// In en, this message translates to:
  /// **'Update your Sure server URL'**
  String get backendConfigSubtitle;

  /// Label for the example URLs info box on the config screen.
  ///
  /// In en, this message translates to:
  /// **'Example URLs'**
  String get backendConfigExampleUrlsLabel;

  /// Label for the server URL field on the config screen.
  ///
  /// In en, this message translates to:
  /// **'Sure server URL'**
  String get backendConfigUrlLabel;

  /// Hint text for the server URL field.
  ///
  /// In en, this message translates to:
  /// **'https://app.sure.am'**
  String get backendConfigUrlHint;

  /// Label for the custom proxy headers section on the config screen.
  ///
  /// In en, this message translates to:
  /// **'Custom proxy headers'**
  String get backendConfigProxyHeadersLabel;

  /// Subtitle for the proxy headers expansion tile when no headers are configured.
  ///
  /// In en, this message translates to:
  /// **'Optional headers for a reverse proxy or auth gateway'**
  String get backendConfigProxyHeadersSubtitle;

  /// Subtitle for the proxy headers expansion tile when headers are configured.
  ///
  /// In en, this message translates to:
  /// **'{count} configured'**
  String backendConfigProxyHeadersCount(int count);

  /// Label on the test-connection button while the test is in progress.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get backendConfigTesting;

  /// Button label to test the server connection.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get backendConfigTestButton;

  /// Button label to proceed after saving configuration.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get backendConfigContinueButton;

  /// Helper text below the config form.
  ///
  /// In en, this message translates to:
  /// **'You can change this later in the settings.'**
  String get backendConfigChangeHint;

  /// App bar title for the recent transactions screen.
  ///
  /// In en, this message translates to:
  /// **'Recent Transactions'**
  String get recentTransactionsTitle;

  /// Empty-state message on the recent transactions screen.
  ///
  /// In en, this message translates to:
  /// **'No Transactions'**
  String get recentTransactionsEmpty;

  /// Tooltip for the display-limit popup menu on the recent transactions screen.
  ///
  /// In en, this message translates to:
  /// **'Display Limit'**
  String get recentTransactionsDisplayLimit;

  /// Menu item label to show N recent transactions.
  ///
  /// In en, this message translates to:
  /// **'Show {count}'**
  String recentTransactionsShowN(int count);

  /// Empty-state subtitle prompting the user to pull to refresh.
  ///
  /// In en, this message translates to:
  /// **'Pull to refresh'**
  String get recentTransactionsPullToRefresh;

  /// App bar title for the log viewer screen.
  ///
  /// In en, this message translates to:
  /// **'Debug Logs'**
  String get logViewerTitle;

  /// Log level filter chip: show all log entries.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get logViewerFilterAll;

  /// Log level filter chip: show info entries only.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get logViewerFilterInfo;

  /// Log level filter chip: show warning entries only.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get logViewerFilterWarning;

  /// Log level filter chip: show error entries only.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get logViewerFilterError;

  /// Log level filter chip: show debug entries only.
  ///
  /// In en, this message translates to:
  /// **'Debug'**
  String get logViewerFilterDebug;

  /// Tooltip for the auto-scroll toggle button when auto-scroll is off.
  ///
  /// In en, this message translates to:
  /// **'Enable auto-scroll'**
  String get logViewerAutoScrollEnable;

  /// Tooltip for the auto-scroll toggle button when auto-scroll is on.
  ///
  /// In en, this message translates to:
  /// **'Disable auto-scroll'**
  String get logViewerAutoScrollDisable;

  /// Tooltip for the copy-logs action button.
  ///
  /// In en, this message translates to:
  /// **'Copy logs'**
  String get logViewerCopyLogs;

  /// Tooltip for the clear-logs action button.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get logViewerClearLogs;

  /// Snackbar message after logs are copied to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Logs copied to clipboard'**
  String get logViewerLogsCopied;

  /// Empty-state message shown when there are no log entries to display.
  ///
  /// In en, this message translates to:
  /// **'No logs yet'**
  String get logViewerEmpty;

  /// Message shown in the connectivity banner when the device has no network.
  ///
  /// In en, this message translates to:
  /// **'You are offline'**
  String get connectivityOffline;

  /// Connectivity banner message showing how many transactions are queued for sync.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} transaction pending sync} other{{count} transactions pending sync}}'**
  String connectivityPendingSync(int count);

  /// Button label in the connectivity banner to trigger an immediate sync.
  ///
  /// In en, this message translates to:
  /// **'Sync Now'**
  String get connectivitySyncNow;

  /// Button label to add a new custom proxy header.
  ///
  /// In en, this message translates to:
  /// **'Add header'**
  String get proxyHeadersAddHeader;

  /// Label for the header-name input field.
  ///
  /// In en, this message translates to:
  /// **'Header name'**
  String get proxyHeadersNameLabel;

  /// Hint text for the header-name input (example header name).
  ///
  /// In en, this message translates to:
  /// **'X-Auth-Token'**
  String get proxyHeadersNameHint;

  /// Label for the header-value input field.
  ///
  /// In en, this message translates to:
  /// **'Header value'**
  String get proxyHeadersValueLabel;

  /// Tooltip for the remove-header icon button.
  ///
  /// In en, this message translates to:
  /// **'Remove header'**
  String get proxyHeadersRemove;

  /// Tooltip for the refresh button on the account detail header.
  ///
  /// In en, this message translates to:
  /// **'Refresh account details'**
  String get accountDetailRefreshTooltip;

  /// Section heading for the balance history chart in the account detail header.
  ///
  /// In en, this message translates to:
  /// **'Recent balance history'**
  String get accountDetailRecentBalanceHistory;

  /// Section heading for the top holdings list in the account detail header.
  ///
  /// In en, this message translates to:
  /// **'Top holdings'**
  String get accountDetailTopHoldings;

  /// Fallback label when a holding has no name.
  ///
  /// In en, this message translates to:
  /// **'Holding'**
  String get accountDetailHoldingFallback;

  /// Label for the cash position chip in the account detail header.
  ///
  /// In en, this message translates to:
  /// **'Cash {amount}'**
  String accountDetailCashChip(String amount);

  /// Snackbar shown on the biometric lock screen when authentication fails.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed. Tap Unlock to try again.'**
  String get biometricLockFailedRetry;

  /// Reason shown in the system biometric prompt when enabling app lock from settings.
  ///
  /// In en, this message translates to:
  /// **'Verify biometric to enable app lock'**
  String get settingsBiometricVerifyReason;

  /// Snackbar shown when biometric verification fails while enabling app lock.
  ///
  /// In en, this message translates to:
  /// **'Biometric authentication failed.'**
  String get settingsBiometricFailed;

  /// Snackbar shown when the app store update link cannot be opened.
  ///
  /// In en, this message translates to:
  /// **'Unable to open store link'**
  String get settingsUpdateOpenStoreError;

  /// Snackbar shown when clearing local data fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to clear local data.'**
  String get settingsClearDataFailed;

  /// Snackbar shown after local data is cleared, prompting the user to pull to refresh.
  ///
  /// In en, this message translates to:
  /// **'Local data cleared successfully. Pull to refresh to sync from server.'**
  String get settingsClearDataSuccessDetailed;

  /// Snackbar shown when the contact/Discord link cannot be opened.
  ///
  /// In en, this message translates to:
  /// **'Unable to open link'**
  String get settingsContactOpenLinkError;

  /// Body text for the reset-account confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Resetting your account will delete all your accounts, categories, merchants, tags, and other data, but keep your user account intact.\n\nThis action cannot be undone. Are you sure?'**
  String get settingsResetAccountContent;

  /// Title and confirm button label for the reset-account action.
  ///
  /// In en, this message translates to:
  /// **'Reset Account'**
  String get settingsResetAccount;

  /// Snackbar shown after an account reset is initiated.
  ///
  /// In en, this message translates to:
  /// **'Account reset has been initiated. This may take a moment.'**
  String get settingsResetAccountInitiated;

  /// Snackbar shown when resetting the account fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to reset account'**
  String get settingsResetAccountFailed;

  /// Body text for the delete-account confirmation dialog on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Deleting your account will permanently remove all your data and cannot be undone.\n\nAre you sure you want to delete your account?'**
  String get settingsDeleteAccountConfirmContent;

  /// Snackbar shown when deleting the account fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete account'**
  String get settingsDeleteAccountFailed;

  /// Explanatory note shown in the custom proxy headers dialog.
  ///
  /// In en, this message translates to:
  /// **'Headers are sent by the app with API requests. External browser SSO pages may not receive them.'**
  String get settingsProxyHeadersNote;

  /// Snackbar shown after custom proxy headers are saved.
  ///
  /// In en, this message translates to:
  /// **'Custom proxy headers saved'**
  String get settingsProxyHeadersSaved;

  /// Snackbar shown when saving custom proxy headers fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to save custom proxy headers.'**
  String get settingsProxyHeadersSaveFailed;

  /// App version list tile title on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'App Version: {version}'**
  String settingsAppVersion(String version);

  /// Subtitle for the check-for-updates list tile.
  ///
  /// In en, this message translates to:
  /// **'See if a newer version is available'**
  String get settingsCheckForUpdatesSubtitle;

  /// Title for the contact-us list tile on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Contact us'**
  String get settingsContactUs;

  /// Accessibility label for the debug logs list tile.
  ///
  /// In en, this message translates to:
  /// **'Open debug logs'**
  String get settingsDebugLogsSemantics;

  /// Subtitle for the debug logs list tile.
  ///
  /// In en, this message translates to:
  /// **'View app diagnostic logs'**
  String get settingsDebugLogsSubtitle;

  /// Title for the group-by-account-type toggle on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Group by Account Type'**
  String get settingsGroupByAccountType;

  /// Subtitle for the group-by-account-type toggle.
  ///
  /// In en, this message translates to:
  /// **'Group accounts by type (Crypto, Bank, etc.)'**
  String get settingsGroupByAccountTypeSubtitle;

  /// Title for the custom proxy headers list tile on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Custom proxy headers'**
  String get settingsProxyHeadersTileTitle;

  /// Subtitle for the custom proxy headers list tile when no headers are configured.
  ///
  /// In en, this message translates to:
  /// **'Optional headers for a reverse proxy or auth gateway'**
  String get settingsProxyHeadersTileSubtitleEmpty;

  /// Subtitle for the custom proxy headers list tile when headers are configured.
  ///
  /// In en, this message translates to:
  /// **'{count} configured'**
  String settingsProxyHeadersTileSubtitleCount(int count);

  /// Subtitle for the clear-local-data list tile.
  ///
  /// In en, this message translates to:
  /// **'Remove all cached transactions and accounts'**
  String get settingsClearDataTileSubtitle;

  /// Subtitle for the reset-account list tile in the danger zone.
  ///
  /// In en, this message translates to:
  /// **'Delete all accounts, categories, merchants, and tags but keep your user account'**
  String get settingsResetAccountTileSubtitle;

  /// Subtitle for the delete-account list tile in the danger zone.
  ///
  /// In en, this message translates to:
  /// **'Permanently remove all your data. This cannot be undone.'**
  String get settingsDeleteAccountTileSubtitle;

  /// Fallback display name when the user has no name set.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get settingsUserFallback;

  /// Body text for the multi-chat delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Delete {count} chat? This cannot be undone.} other{Delete {count} chats? This cannot be undone.}}'**
  String chatListDeleteMultiContent(int count);

  /// Snackbar shown after multiple chats are deleted.
  ///
  /// In en, this message translates to:
  /// **'Chats deleted'**
  String get chatListDeletedSuccess;

  /// Snackbar shown when deleting multiple chats fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete chats'**
  String get chatListDeleteFailed;

  /// Error-state heading on the chat list screen.
  ///
  /// In en, this message translates to:
  /// **'Failed to load chats'**
  String get chatListError;

  /// Relative time label for very recent chats.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get chatListJustNow;

  /// Body text for the single-chat delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{title}\"?'**
  String chatListDeleteSingleContent(String title);

  /// Snackbar shown when the sign-up page cannot be opened.
  ///
  /// In en, this message translates to:
  /// **'Unable to open sign up page'**
  String get loginSignUpOpenError;

  /// Title for the API key login dialog on the login screen.
  ///
  /// In en, this message translates to:
  /// **'API Key Login'**
  String get loginApiKeyDialogTitle;

  /// Body text for the API key login dialog.
  ///
  /// In en, this message translates to:
  /// **'Enter your API key to sign in.'**
  String get loginApiKeyDialogBody;

  /// Fallback error shown when an API key login fails.
  ///
  /// In en, this message translates to:
  /// **'Invalid API key'**
  String get loginApiKeyInvalid;

  /// Sign-in button label in the API key login dialog.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get loginApiKeySignIn;

  /// Leading text before the Sign Up link on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Demo account or '**
  String get loginDemoOrSignUpPrefix;

  /// Tappable Sign Up link text on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Sign Up'**
  String get loginSignUpLink;

  /// Trailing punctuation after the Sign Up link on the login screen.
  ///
  /// In en, this message translates to:
  /// **'!'**
  String get loginSignUpSuffix;

  /// Info banner shown when MFA is required during login.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication is enabled. Enter your code.'**
  String get loginMfaInfo;

  /// Validation error when the MFA code field is empty.
  ///
  /// In en, this message translates to:
  /// **'Please enter your authentication code'**
  String get loginMfaCodeRequired;

  /// Divider label between primary and alternate sign-in options.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get loginOrDivider;

  /// Heading above the displayed server URL on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Sure server URL:'**
  String get loginServerUrlHeading;

  /// Button label to open the API key login dialog.
  ///
  /// In en, this message translates to:
  /// **'API-Key Login'**
  String get loginApiKeyLoginButton;

  /// Tooltip for the backend settings button on the login screen.
  ///
  /// In en, this message translates to:
  /// **'Backend Settings'**
  String get loginBackendSettingsTooltip;

  /// Snackbar shown when the session expires while editing a transaction.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please login again.'**
  String get transactionEditSessionExpired;

  /// Snackbar shown after a transaction is updated successfully.
  ///
  /// In en, this message translates to:
  /// **'Transaction updated'**
  String get transactionEditUpdated;

  /// Fallback snackbar shown when updating a transaction fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to update transaction'**
  String get transactionEditUpdateFailed;

  /// Validation error when the transaction name exceeds the maximum length.
  ///
  /// In en, this message translates to:
  /// **'Name must be {max} characters or fewer'**
  String transactionEditNameMaxLength(int max);

  /// Validation error when the transaction name contains control characters.
  ///
  /// In en, this message translates to:
  /// **'Name contains unsupported characters'**
  String get transactionEditNameInvalidChars;

  /// Validation error when the notes exceed the maximum length.
  ///
  /// In en, this message translates to:
  /// **'Notes must be {max} characters or fewer'**
  String transactionEditNotesMaxLength(int max);

  /// Validation error when the notes contain control characters.
  ///
  /// In en, this message translates to:
  /// **'Notes contain unsupported characters'**
  String get transactionEditNotesInvalidChars;

  /// Dropdown option representing no selected category in the edit form.
  ///
  /// In en, this message translates to:
  /// **'No category'**
  String get transactionEditNoCategory;

  /// Fallback dropdown label for the currently selected category when its name is unknown.
  ///
  /// In en, this message translates to:
  /// **'Current category'**
  String get transactionEditCurrentCategory;

  /// Dropdown option representing no selected merchant in the edit form.
  ///
  /// In en, this message translates to:
  /// **'No merchant'**
  String get transactionEditNoMerchant;

  /// Fallback dropdown label for the currently selected merchant when its name is unknown.
  ///
  /// In en, this message translates to:
  /// **'Current merchant'**
  String get transactionEditCurrentMerchant;

  /// Message shown when no tags are available to select in the edit form.
  ///
  /// In en, this message translates to:
  /// **'No tags available'**
  String get transactionEditNoTags;

  /// Fallback label for a selected tag whose name is unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown tag'**
  String get transactionEditUnknownTag;

  /// Notice shown when a transaction cannot be edited because it is not yet synced.
  ///
  /// In en, this message translates to:
  /// **'Only synced transactions can be edited from mobile.'**
  String get transactionEditSyncedOnly;

  /// Helper text under the category dropdown in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Choose a replacement category'**
  String get transactionEditCategoryHelper;

  /// Helper text under the merchant dropdown in the edit form.
  ///
  /// In en, this message translates to:
  /// **'Choose a replacement merchant'**
  String get transactionEditMerchantHelper;

  /// Snackbar shown when the session expires while creating a transaction.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please login again.'**
  String get transactionFormSessionExpired;

  /// Validation error when the amount field is empty in the create form.
  ///
  /// In en, this message translates to:
  /// **'Please enter an amount'**
  String get transactionFormAmountRequiredPrompt;

  /// Validation error when the amount is not a valid number.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid number'**
  String get transactionFormAmountInvalidNumber;

  /// Validation error when the amount is zero or negative.
  ///
  /// In en, this message translates to:
  /// **'Amount must be greater than 0'**
  String get transactionFormAmountTooSmall;

  /// Snackbar shown after a transaction is created while online.
  ///
  /// In en, this message translates to:
  /// **'Transaction created successfully'**
  String get transactionFormCreateSuccessOnline;

  /// Snackbar shown after a transaction is saved while offline.
  ///
  /// In en, this message translates to:
  /// **'Transaction saved (will sync when online)'**
  String get transactionFormCreateSuccessOffline;

  /// Snackbar shown when creating a transaction fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to create transaction'**
  String get transactionFormCreateFailed;

  /// Snackbar shown when an unexpected error occurs while creating a transaction.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String transactionFormGenericError(String error);

  /// Toggle label to hide the optional transaction fields.
  ///
  /// In en, this message translates to:
  /// **'Less'**
  String get transactionFormLess;

  /// Toggle label to show the optional transaction fields.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get transactionFormMore;

  /// Helper text for the date field in the create form.
  ///
  /// In en, this message translates to:
  /// **'Optional (default: today)'**
  String get transactionFormDateHelper;

  /// Helper text for the name field in the create form.
  ///
  /// In en, this message translates to:
  /// **'Optional (default: SureApp)'**
  String get transactionFormNameHelper;

  /// Placeholder shown while categories are loading in the create form.
  ///
  /// In en, this message translates to:
  /// **'Loading categories…'**
  String get transactionFormCategoryLoading;

  /// Helper text for the category dropdown in the create form.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get transactionFormCategoryHelper;

  /// Dropdown option representing no selected category in the create form.
  ///
  /// In en, this message translates to:
  /// **'No category'**
  String get transactionFormNoCategory;

  /// Submit button label on the create-transaction form.
  ///
  /// In en, this message translates to:
  /// **'Create Transaction'**
  String get transactionFormCreateButton;

  /// Helper text under the amount field indicating it is required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get transactionFormAmountHelper;

  /// Body text for the clear-logs confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear all logs?'**
  String get logViewerClearConfirm;

  /// Confirm button label in the clear-logs dialog.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get logViewerClear;

  /// Title for the edit-chat-title dialog.
  ///
  /// In en, this message translates to:
  /// **'Edit Title'**
  String get chatConversationEditTitle;

  /// Label for the chat title input field in the edit dialog.
  ///
  /// In en, this message translates to:
  /// **'Chat Title'**
  String get chatConversationTitleLabel;

  /// Tooltip for the refresh button in the chat conversation screen.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get chatConversationRefreshTooltip;

  /// Error-state heading when a chat fails to load.
  ///
  /// In en, this message translates to:
  /// **'Failed to load chat'**
  String get chatConversationLoadError;

  /// Title for the dialog prompting the user to enable AI chat.
  ///
  /// In en, this message translates to:
  /// **'Turn on AI Chat?'**
  String get navEnableAiChatTitle;

  /// Body text for the enable-AI-chat dialog.
  ///
  /// In en, this message translates to:
  /// **'AI Chat is currently disabled in your account settings. Would you like to turn it on now?'**
  String get navEnableAiChatContent;

  /// Dismiss button in the enable-AI-chat dialog.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get navEnableAiChatNotNow;

  /// Confirm button in the enable-AI-chat dialog.
  ///
  /// In en, this message translates to:
  /// **'Turn on AI'**
  String get navEnableAiChatConfirm;

  /// Snackbar shown when enabling AI chat fails.
  ///
  /// In en, this message translates to:
  /// **'Unable to enable AI right now.'**
  String get navEnableAiChatFailed;

  /// Tooltip for the edit button on a transaction row.
  ///
  /// In en, this message translates to:
  /// **'Edit transaction'**
  String get transactionsListEditTooltip;

  /// Snackbar shown when trying to sync without being signed in.
  ///
  /// In en, this message translates to:
  /// **'Please sign in to sync transactions'**
  String get connectivitySignInToSync;

  /// Snackbar shown after transactions sync successfully.
  ///
  /// In en, this message translates to:
  /// **'Transactions synced successfully'**
  String get connectivitySyncSuccess;

  /// Snackbar shown when a manual sync fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to sync transactions. Please try again.'**
  String get connectivitySyncFailed;

  /// Snackbar shown when authentication fails during a manual sync.
  ///
  /// In en, this message translates to:
  /// **'Unable to authenticate. Please try again.'**
  String get connectivityAuthFailed;

  /// Header text on the SSO onboarding screen showing the signed-in Google email.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {email}'**
  String ssoOnboardingSignedInAs(String email);

  /// Header text on the SSO onboarding screen when the Google email is unknown.
  ///
  /// In en, this message translates to:
  /// **'Google account verified'**
  String get ssoOnboardingGoogleVerified;

  /// Explanatory note on the link-existing form prompting the user to enter their credentials.
  ///
  /// In en, this message translates to:
  /// **'Enter your existing account credentials to link with Google Sign-In.'**
  String get ssoOnboardingLinkCredentialsNote;

  /// Explanatory note on the create form when the user has a pending household invitation.
  ///
  /// In en, this message translates to:
  /// **'You have a pending invitation. Accept it to join an existing household.'**
  String get ssoOnboardingPendingInvitationNote;

  /// Explanatory note on the create form when creating a brand-new account via Google.
  ///
  /// In en, this message translates to:
  /// **'Create a new account using your Google identity.'**
  String get ssoOnboardingCreateIdentityNote;

  /// Validation error when the first-name field is empty on the SSO onboarding screen.
  ///
  /// In en, this message translates to:
  /// **'First name is required'**
  String get ssoOnboardingFirstNameRequired;

  /// Validation error when the last-name field is empty on the SSO onboarding screen.
  ///
  /// In en, this message translates to:
  /// **'Last name is required'**
  String get ssoOnboardingLastNameRequired;

  /// Error shown when the connection test times out.
  ///
  /// In en, this message translates to:
  /// **'Connection timeout. Please check the URL and try again.'**
  String get backendConfigTimeout;

  /// Message shown when the connection test succeeds.
  ///
  /// In en, this message translates to:
  /// **'Connection successful!'**
  String get backendConfigSuccess;

  /// Error shown when the server returns a non-success status during the connection test.
  ///
  /// In en, this message translates to:
  /// **'Server responded with status {code}. Please check if this is a Sure backend server.'**
  String backendConfigServerError(int code);

  /// Error shown when the connection test fails with an exception.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {error}'**
  String backendConfigConnectionFailed(String error);

  /// Error shown when saving the backend URL fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to save URL: {error}'**
  String backendConfigSaveFailed(String error);

  /// Validation error when the backend URL field is empty.
  ///
  /// In en, this message translates to:
  /// **'Please enter a backend URL'**
  String get backendConfigUrlRequired;

  /// Validation error when the backend URL is missing an http(s) scheme.
  ///
  /// In en, this message translates to:
  /// **'URL must start with http:// or https://'**
  String get backendConfigUrlScheme;

  /// Validation error when the backend URL is malformed.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid URL'**
  String get backendConfigUrlInvalid;

  /// Helper text below the custom proxy headers section on the backend config screen.
  ///
  /// In en, this message translates to:
  /// **'Headers are sent by the app with API requests. External browser SSO pages may not receive them.'**
  String get backendConfigHeadersHelp;

  /// Fallback label when a transaction's account cannot be resolved.
  ///
  /// In en, this message translates to:
  /// **'Unknown Account'**
  String get recentTransactionsUnknownAccount;

  /// Error message shown when account detail and balances both fail to load.
  ///
  /// In en, this message translates to:
  /// **'Account details are temporarily unavailable'**
  String get accountDetailUnavailable;

  /// Relative time label for a chat updated some minutes ago.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String chatListMinutesAgo(int minutes);

  /// Relative time label for a chat updated some hours ago.
  ///
  /// In en, this message translates to:
  /// **'{hours}h ago'**
  String chatListHoursAgo(int hours);

  /// Relative time label for a chat updated some days ago.
  ///
  /// In en, this message translates to:
  /// **'{days}d ago'**
  String chatListDaysAgo(int days);

  /// Fallback snackbar shown when creating a new conversation from the first message fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to start conversation. Please try again.'**
  String get chatConversationStartFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
