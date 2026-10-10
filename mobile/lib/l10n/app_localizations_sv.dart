// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Swedish (`sv`).
class AppLocalizationsSv extends AppLocalizations {
  AppLocalizationsSv([String locale = 'sv']) : super(locale);

  @override
  String get appTitle => 'Sure Finances';

  @override
  String get commonCancel => 'Avbryt';

  @override
  String get commonSave => 'Spara';

  @override
  String get commonTryAgain => 'Försök igen';

  @override
  String get commonDelete => 'Radera';

  @override
  String get commonAll => 'Alla';

  @override
  String get commonRefresh => 'Uppdatera';

  @override
  String get commonClose => 'Stäng';

  @override
  String get commonUndo => 'Ångra';

  @override
  String get chatSuggestionNetWorth => 'Vad är min nettoförmögenhet just nu?';

  @override
  String get chatSuggestionSpending =>
      'Hur har mina utgifter förändrats den här månaden?';

  @override
  String get chatSuggestionSavings => 'Hur kan jag öka min sparkvot?';

  @override
  String get chatSuggestionExpenses =>
      'Vilka är mina största utgifter på sistone?';

  @override
  String get loginEmailLabel => 'E-post';

  @override
  String get loginEmailRequired => 'E-post krävs';

  @override
  String get loginEmailInvalid => 'Ange en giltig e-postadress';

  @override
  String get loginPasswordLabel => 'Lösenord';

  @override
  String get loginPasswordRequired => 'Lösenord krävs';

  @override
  String get loginSignIn => 'Logga in';

  @override
  String get loginSignInWithGoogle => 'Logga in med Google';

  @override
  String get loginMfaLabel => 'Autentiseringskod';

  @override
  String get loginApiKeyLabel => 'API-nyckel';

  @override
  String get navHome => 'Hem';

  @override
  String get navIntro => 'Intro';

  @override
  String get navAssistant => 'Assistent';

  @override
  String get navMore => 'Mer';

  @override
  String get dashboardSyncError => 'Synkningen misslyckades';

  @override
  String get dashboardSyncFailed => 'Synkningen misslyckades. Försök igen.';

  @override
  String get dashboardRefreshing => 'Uppdaterar konton…';

  @override
  String get dashboardAccountsUpdated => 'Kontona har uppdaterats';

  @override
  String get dashboardSyncing => 'Synkar data från servern…';

  @override
  String get dashboardSynced => 'Synkat';

  @override
  String get dashboardErrorLoadingAccounts =>
      'Det gick inte att läsa in konton';

  @override
  String get dashboardNoAccounts => 'Inga konton än';

  @override
  String get dashboardNoAccountsSubtitle =>
      'Lägg till konton i webbappen för att se dem här.';

  @override
  String get dashboardFilterEmpty => 'Inga konton matchar det aktuella filtret';

  @override
  String get chatListTitle => 'Chattar';

  @override
  String get chatListNewChat => 'Ny chatt';

  @override
  String get chatListEmpty => 'Inga chattar än';

  @override
  String get chatListEmptySubtitle =>
      'Starta en konversation med din AI-assistent';

  @override
  String get chatListDeleteTitle => 'Radera chatt';

  @override
  String get chatConversationNewTitle => 'Ny konversation';

  @override
  String get chatConversationMessageHint =>
      'Fråga vad som helst om din ekonomi…';

  @override
  String chatConversationGreetingWithName(String firstName) {
    return 'Hej $firstName, vad kan jag hjälpa dig med?';
  }

  @override
  String get chatConversationGreetingNoName =>
      'Hej, vad kan jag hjälpa dig med?';

  @override
  String get transactionFormNewTitle => 'Ny transaktion';

  @override
  String get transactionFormTypeLabel => 'Typ';

  @override
  String get transactionFormTypeExpense => 'Utgift';

  @override
  String get transactionFormTypeIncome => 'Inkomst';

  @override
  String get transactionFormAmountLabel => 'Belopp';

  @override
  String get transactionFormAmountRequired => 'Belopp krävs';

  @override
  String get transactionFormAmountInvalid => 'Ange ett giltigt belopp';

  @override
  String get transactionFormDateLabel => 'Datum';

  @override
  String get transactionFormNameLabel => 'Namn';

  @override
  String get transactionFormCategoryLabel => 'Kategori';

  @override
  String get transactionEditTitle => 'Redigera transaktion';

  @override
  String get transactionEditNameLabel => 'Namn';

  @override
  String get transactionEditNameRequired => 'Namn krävs';

  @override
  String get transactionEditNotesLabel => 'Anteckningar';

  @override
  String get transactionEditCategoryLabel => 'Kategori';

  @override
  String get transactionEditMerchantLabel => 'Handlare';

  @override
  String get transactionEditTagsLabel => 'Taggar';

  @override
  String get transactionEditSaving => 'Sparar…';

  @override
  String get transactionsListDeleteTitle => 'Radera transaktion';

  @override
  String transactionsListDeleteSingleContent(String name) {
    return 'Vill du verkligen radera \"$name\"?';
  }

  @override
  String get transactionsListDeleteMultiTitle => 'Radera transaktioner';

  @override
  String get transactionsListDeleteMultiContent =>
      'Vill du verkligen radera de valda transaktionerna?';

  @override
  String get transactionsListEmpty => 'Inga transaktioner';

  @override
  String get transactionsListAuthFailed =>
      'Autentiseringen misslyckades: logga in igen';

  @override
  String get transactionsListNoTransactionsYet => 'Inga transaktioner än';

  @override
  String get transactionsListEmptyAddFirst =>
      'Tryck på + för att lägga till din första transaktion';

  @override
  String get transactionsListNoCategoryMatch =>
      'Inga transaktioner matchar den här kategorin';

  @override
  String get transactionsListRetry => 'Försök igen';

  @override
  String get transactionsListDeletedSuccess => 'Transaktionen har raderats';

  @override
  String get transactionsListSingleDeleteFailed =>
      'Det gick inte att radera transaktionen';

  @override
  String transactionsListDeletedMulti(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Raderade $count transaktioner',
      one: 'Raderade $count transaktion',
    );
    return '$_temp0';
  }

  @override
  String get transactionsListDeleteFailed =>
      'Det gick inte att radera transaktionerna';

  @override
  String get transactionsListDeleteNoToken =>
      'Det gick inte att radera: ingen åtkomsttoken';

  @override
  String get transactionsListUndoTitle => 'Ångra transaktion';

  @override
  String get transactionsListUndoRemovePending =>
      'Ta bort den här väntande transaktionen?';

  @override
  String get transactionsListUndoRestoreConfirm =>
      'Återställa den här transaktionen?';

  @override
  String get transactionsListUndoPendingRemoved =>
      'Den väntande transaktionen har tagits bort';

  @override
  String get transactionsListUndoRestored => 'Transaktionen har återställts';

  @override
  String get transactionsListUndoFailed =>
      'Det gick inte att ångra transaktionen';

  @override
  String get settingsSectionDisplay => 'Visning';

  @override
  String get settingsSectionConnection => 'Anslutning';

  @override
  String get settingsSectionDataManagement => 'Datahantering';

  @override
  String get settingsSectionSecurity => 'Säkerhet';

  @override
  String get settingsSectionDangerZone => 'Riskzon';

  @override
  String get settingsThemeLabel => 'Tema';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Ljust';

  @override
  String get settingsThemeDark => 'Mörkt';

  @override
  String get settingsProxyHeadersLabel => 'Anpassade proxyheaders';

  @override
  String get settingsPrivacyHideAmountsLabel => 'Dölj belopp';

  @override
  String get settingsPrivacyHideAmountsContent => 'Maskera belopp i hela appen';

  @override
  String get settingsBiometricLabel => 'Biometriskt lås';

  @override
  String get settingsBiometricEnable => 'Aktivera biometriskt lås?';

  @override
  String get settingsBiometricEnableContent =>
      'Kräv biometrisk autentisering när du återgår till appen.';

  @override
  String get settingsCheckForUpdates => 'Sök efter uppdateringar';

  @override
  String get settingsUpdateAvailableTitle => 'Uppdatering tillgänglig';

  @override
  String settingsUpdateAvailableContent(String version) {
    return 'Version $version finns tillgänglig. Vill du uppdatera nu?';
  }

  @override
  String get settingsUpdateNewerVersionFallback => 'en nyare version';

  @override
  String get settingsUpdateNow => 'Uppdatera nu';

  @override
  String get settingsNoUpdateAvailable => 'Du har den senaste versionen.';

  @override
  String get settingsUpdateError =>
      'Det gick inte att söka efter uppdateringar.';

  @override
  String get settingsClearDataTitle => 'Rensa all data';

  @override
  String get settingsClearDataContent =>
      'Detta tar bort all lokalt cachad data. Din data på servern påverkas inte.';

  @override
  String get settingsClearData => 'Rensa data';

  @override
  String get settingsClearDataSuccess => 'Lokal data har rensats';

  @override
  String get settingsDeleteAccountTitle => 'Radera användarkonto';

  @override
  String get settingsDeleteAccount => 'Radera användarkonto';

  @override
  String get settingsSignOutTitle => 'Logga ut';

  @override
  String get settingsSignOutContent => 'Vill du verkligen logga ut?';

  @override
  String get settingsSignOut => 'Logga ut';

  @override
  String get settingsDebugLogs => 'Felsökningsloggar';

  @override
  String get ssoOnboardingTitle => 'Koppla ditt användarkonto';

  @override
  String get ssoOnboardingTabLink => 'Koppla befintligt';

  @override
  String get ssoOnboardingTabCreate => 'Skapa nytt';

  @override
  String get ssoOnboardingFirstNameLabel => 'Förnamn';

  @override
  String get ssoOnboardingLastNameLabel => 'Efternamn';

  @override
  String get ssoOnboardingLinkButton => 'Koppla användarkonto';

  @override
  String get ssoOnboardingCreateButton => 'Skapa användarkonto';

  @override
  String get ssoOnboardingAcceptInvitation => 'Acceptera inbjudan';

  @override
  String get calendarTitle => 'Kontokalender';

  @override
  String get calendarAccountTypeSection => 'Kontotyp';

  @override
  String get calendarSegmentAssets => 'Tillgångar';

  @override
  String get calendarSegmentLiabilities => 'Skulder';

  @override
  String get calendarSelectAccount => 'Välj konto';

  @override
  String get calendarMonthlyChange => 'Månadsförändring';

  @override
  String get calendarNoTransactions => 'Inga transaktioner den här dagen';

  @override
  String get moreCalendar => 'Kontokalender';

  @override
  String get moreCalendarSubtitle => 'Se månatliga saldoförändringar per konto';

  @override
  String get moreRecentTransactions => 'Senaste transaktioner';

  @override
  String get moreRecentTransactionsSubtitle =>
      'Se de senaste transaktionerna för alla konton';

  @override
  String get biometricTitle => 'Appen är låst';

  @override
  String get biometricSubtitle => 'Autentisera dig för att fortsätta';

  @override
  String get biometricUnlock => 'Lås upp';

  @override
  String get biometricAuthenticating => 'Autentiserar…';

  @override
  String get biometricLogOut => 'Logga ut';

  @override
  String get backendConfigTitle => 'Konfiguration';

  @override
  String get backendConfigSubtitle => 'Uppdatera adressen till din Sure-server';

  @override
  String get backendConfigExampleUrlsLabel => 'Exempeladresser';

  @override
  String get backendConfigUrlLabel => 'Adress till Sure-servern';

  @override
  String get backendConfigUrlHint => 'https://app.sure.am';

  @override
  String get backendConfigProxyHeadersLabel => 'Anpassade proxyheaders';

  @override
  String get backendConfigProxyHeadersSubtitle =>
      'Valfria headers för en omvänd proxy eller autentiseringsgateway';

  @override
  String backendConfigProxyHeadersCount(int count) {
    return '$count konfigurerade';
  }

  @override
  String get backendConfigTesting => 'Testar…';

  @override
  String get backendConfigTestButton => 'Testa anslutningen';

  @override
  String get backendConfigContinueButton => 'Fortsätt';

  @override
  String get backendConfigChangeHint =>
      'Du kan ändra detta senare i inställningarna.';

  @override
  String get recentTransactionsTitle => 'Senaste transaktioner';

  @override
  String get recentTransactionsEmpty => 'Inga transaktioner';

  @override
  String get recentTransactionsDisplayLimit => 'Visningsgräns';

  @override
  String recentTransactionsShowN(int count) {
    return 'Visa $count';
  }

  @override
  String get recentTransactionsPullToRefresh => 'Dra nedåt för att uppdatera';

  @override
  String get logViewerTitle => 'Felsökningsloggar';

  @override
  String get logViewerFilterAll => 'Alla';

  @override
  String get logViewerFilterInfo => 'Info';

  @override
  String get logViewerFilterWarning => 'Varning';

  @override
  String get logViewerFilterError => 'Fel';

  @override
  String get logViewerFilterDebug => 'Felsökning';

  @override
  String get logViewerAutoScrollEnable => 'Aktivera automatisk rullning';

  @override
  String get logViewerAutoScrollDisable => 'Inaktivera automatisk rullning';

  @override
  String get logViewerCopyLogs => 'Kopiera loggar';

  @override
  String get logViewerClearLogs => 'Rensa loggar';

  @override
  String get logViewerLogsCopied => 'Loggarna har kopierats till urklipp';

  @override
  String get logViewerEmpty => 'Inga loggar än';

  @override
  String get connectivityOffline => 'Du är offline';

  @override
  String connectivityPendingSync(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transaktioner väntar på synkning',
      one: '$count transaktion väntar på synkning',
    );
    return '$_temp0';
  }

  @override
  String get connectivitySyncNow => 'Synka nu';

  @override
  String get proxyHeadersAddHeader => 'Lägg till header';

  @override
  String get proxyHeadersNameLabel => 'Headernamn';

  @override
  String get proxyHeadersNameHint => 'X-Auth-Token';

  @override
  String get proxyHeadersValueLabel => 'Headervärde';

  @override
  String get proxyHeadersRemove => 'Ta bort header';

  @override
  String get accountDetailRefreshTooltip => 'Uppdatera kontouppgifter';

  @override
  String get accountDetailRecentBalanceHistory => 'Senaste saldohistorik';

  @override
  String get accountDetailTopHoldings => 'Största innehav';

  @override
  String get accountDetailHoldingFallback => 'Innehav';

  @override
  String accountDetailCashChip(String amount) {
    return 'Kontanter $amount';
  }

  @override
  String get biometricLockFailedRetry =>
      'Autentiseringen misslyckades. Tryck på Lås upp för att försöka igen.';

  @override
  String get settingsBiometricVerifyReason =>
      'Verifiera med biometri för att aktivera applåset';

  @override
  String get settingsBiometricFailed =>
      'Den biometriska autentiseringen misslyckades.';

  @override
  String get settingsUpdateOpenStoreError =>
      'Det gick inte att öppna länken till butiken';

  @override
  String get settingsClearDataFailed => 'Det gick inte att rensa lokal data.';

  @override
  String get settingsClearDataSuccessDetailed =>
      'Lokal data har rensats. Dra nedåt för att synka från servern.';

  @override
  String get settingsContactOpenLinkError => 'Det gick inte att öppna länken';

  @override
  String get settingsResetAccountContent =>
      'Om du återställer ditt användarkonto raderas alla dina konton, kategorier, handlare, taggar och annan data, men själva användarkontot finns kvar.\n\nDet går inte att ångra. Är du säker?';

  @override
  String get settingsResetAccount => 'Återställ användarkonto';

  @override
  String get settingsResetAccountInitiated =>
      'Återställningen har startats. Det kan ta en stund.';

  @override
  String get settingsResetAccountFailed =>
      'Det gick inte att återställa användarkontot';

  @override
  String get settingsDeleteAccountConfirmContent =>
      'Om du raderar ditt användarkonto tas all din data bort permanent. Det går inte att ångra.\n\nVill du verkligen radera ditt användarkonto?';

  @override
  String get settingsDeleteAccountFailed =>
      'Det gick inte att radera användarkontot';

  @override
  String get settingsProxyHeadersNote =>
      'Headers skickas av appen med API-anrop. SSO-sidor i extern webbläsare får dem kanske inte.';

  @override
  String get settingsProxyHeadersSaved => 'Anpassade proxyheaders har sparats';

  @override
  String get settingsProxyHeadersSaveFailed =>
      'Det gick inte att spara anpassade proxyheaders.';

  @override
  String settingsAppVersion(String version) {
    return 'Appversion: $version';
  }

  @override
  String get settingsCheckForUpdatesSubtitle =>
      'Se om en nyare version finns tillgänglig';

  @override
  String get settingsContactUs => 'Kontakta oss';

  @override
  String get settingsDebugLogsSemantics => 'Öppna felsökningsloggar';

  @override
  String get settingsDebugLogsSubtitle => 'Visa appens diagnostikloggar';

  @override
  String get settingsGroupByAccountType => 'Gruppera efter kontotyp';

  @override
  String get settingsGroupByAccountTypeSubtitle =>
      'Gruppera konton efter typ (krypto, bank osv.)';

  @override
  String get settingsProxyHeadersTileTitle => 'Anpassade proxyheaders';

  @override
  String get settingsProxyHeadersTileSubtitleEmpty =>
      'Valfria headers för en omvänd proxy eller autentiseringsgateway';

  @override
  String settingsProxyHeadersTileSubtitleCount(int count) {
    return '$count konfigurerade';
  }

  @override
  String get settingsClearDataTileSubtitle =>
      'Ta bort alla cachade transaktioner och konton';

  @override
  String get settingsResetAccountTileSubtitle =>
      'Radera alla konton, kategorier, handlare och taggar men behåll ditt användarkonto';

  @override
  String get settingsDeleteAccountTileSubtitle =>
      'Ta bort all din data permanent. Det går inte att ångra.';

  @override
  String get settingsUserFallback => 'Användare';

  @override
  String chatListDeleteMultiContent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Radera $count chattar? Det går inte att ångra.',
      one: 'Radera $count chatt? Det går inte att ångra.',
    );
    return '$_temp0';
  }

  @override
  String get chatListDeletedSuccess => 'Chattarna har raderats';

  @override
  String get chatListDeleteFailed => 'Det gick inte att radera chattarna';

  @override
  String get chatListError => 'Det gick inte att läsa in chattar';

  @override
  String get chatListJustNow => 'Nyss';

  @override
  String chatListDeleteSingleContent(String title) {
    return 'Vill du verkligen radera \"$title\"?';
  }

  @override
  String get loginSignUpOpenError =>
      'Det gick inte att öppna registreringssidan';

  @override
  String get loginApiKeyDialogTitle => 'Inloggning med API-nyckel';

  @override
  String get loginApiKeyDialogBody => 'Ange din API-nyckel för att logga in.';

  @override
  String get loginApiKeyInvalid => 'Ogiltig API-nyckel';

  @override
  String get loginApiKeySignIn => 'Logga in';

  @override
  String get loginDemoOrSignUpPrefix => 'Demokonto eller ';

  @override
  String get loginSignUpLink => 'Registrera dig';

  @override
  String get loginSignUpSuffix => '!';

  @override
  String get loginMfaInfo =>
      'Tvåfaktorsautentisering är aktiverad. Ange din kod.';

  @override
  String get loginMfaCodeRequired => 'Ange din autentiseringskod';

  @override
  String get loginOrDivider => 'eller';

  @override
  String get loginServerUrlHeading => 'Adress till Sure-servern:';

  @override
  String get loginApiKeyLoginButton => 'Logga in med API-nyckel';

  @override
  String get loginBackendSettingsTooltip => 'Serverinställningar';

  @override
  String get transactionEditSessionExpired =>
      'Sessionen har gått ut. Logga in igen.';

  @override
  String get transactionEditUpdated => 'Transaktionen har uppdaterats';

  @override
  String get transactionEditUpdateFailed =>
      'Det gick inte att uppdatera transaktionen';

  @override
  String transactionEditNameMaxLength(int max) {
    return 'Namnet får vara högst $max tecken';
  }

  @override
  String get transactionEditNameInvalidChars =>
      'Namnet innehåller tecken som inte stöds';

  @override
  String transactionEditNotesMaxLength(int max) {
    return 'Anteckningarna får vara högst $max tecken';
  }

  @override
  String get transactionEditNotesInvalidChars =>
      'Anteckningarna innehåller tecken som inte stöds';

  @override
  String get transactionEditNoCategory => 'Ingen kategori';

  @override
  String get transactionEditCurrentCategory => 'Nuvarande kategori';

  @override
  String get transactionEditNoMerchant => 'Ingen handlare';

  @override
  String get transactionEditCurrentMerchant => 'Nuvarande handlare';

  @override
  String get transactionEditNoTags => 'Inga taggar tillgängliga';

  @override
  String get transactionEditUnknownTag => 'Okänd tagg';

  @override
  String get transactionEditSyncedOnly =>
      'Bara synkade transaktioner kan redigeras i mobilen.';

  @override
  String get transactionEditCategoryHelper => 'Välj en ny kategori';

  @override
  String get transactionEditMerchantHelper => 'Välj en ny handlare';

  @override
  String get transactionFormSessionExpired =>
      'Sessionen har gått ut. Logga in igen.';

  @override
  String get transactionFormAmountRequiredPrompt => 'Ange ett belopp';

  @override
  String get transactionFormAmountInvalidNumber => 'Ange ett giltigt tal';

  @override
  String get transactionFormAmountTooSmall => 'Beloppet måste vara större än 0';

  @override
  String get transactionFormCreateSuccessOnline => 'Transaktionen har skapats';

  @override
  String get transactionFormCreateSuccessOffline =>
      'Transaktionen har sparats (synkas när du är online)';

  @override
  String get transactionFormCreateFailed =>
      'Det gick inte att skapa transaktionen';

  @override
  String transactionFormGenericError(String error) {
    return 'Fel: $error';
  }

  @override
  String get transactionFormLess => 'Mindre';

  @override
  String get transactionFormMore => 'Mer';

  @override
  String get transactionFormDateHelper => 'Valfritt (standard: i dag)';

  @override
  String get transactionFormNameHelper => 'Valfritt (standard: SureApp)';

  @override
  String get transactionFormCategoryLoading => 'Läser in kategorier…';

  @override
  String get transactionFormCategoryHelper => 'Valfritt';

  @override
  String get transactionFormNoCategory => 'Ingen kategori';

  @override
  String get transactionFormCreateButton => 'Skapa transaktion';

  @override
  String get transactionFormAmountHelper => 'Obligatoriskt';

  @override
  String get logViewerClearConfirm => 'Vill du verkligen rensa alla loggar?';

  @override
  String get logViewerClear => 'Rensa';

  @override
  String get chatConversationEditTitle => 'Redigera titel';

  @override
  String get chatConversationTitleLabel => 'Chattitel';

  @override
  String get chatConversationRefreshTooltip => 'Uppdatera';

  @override
  String get chatConversationLoadError => 'Det gick inte att läsa in chatten';

  @override
  String get navEnableAiChatTitle => 'Aktivera AI-chatt?';

  @override
  String get navEnableAiChatContent =>
      'AI-chatt är för närvarande avstängd i dina kontoinställningar. Vill du aktivera den nu?';

  @override
  String get navEnableAiChatNotNow => 'Inte nu';

  @override
  String get navEnableAiChatConfirm => 'Aktivera AI';

  @override
  String get navEnableAiChatFailed => 'Det gick inte att aktivera AI just nu.';

  @override
  String get transactionsListEditTooltip => 'Redigera transaktion';

  @override
  String get connectivitySignInToSync => 'Logga in för att synka transaktioner';

  @override
  String get connectivitySyncSuccess => 'Transaktionerna har synkats';

  @override
  String get connectivitySyncFailed =>
      'Det gick inte att synka transaktionerna. Försök igen.';

  @override
  String get connectivityAuthFailed =>
      'Det gick inte att autentisera. Försök igen.';

  @override
  String ssoOnboardingSignedInAs(String email) {
    return 'Inloggad som $email';
  }

  @override
  String get ssoOnboardingGoogleVerified => 'Google-kontot har verifierats';

  @override
  String get ssoOnboardingLinkCredentialsNote =>
      'Ange uppgifterna för ditt befintliga användarkonto för att koppla det till Google-inloggning.';

  @override
  String get ssoOnboardingPendingInvitationNote =>
      'Du har en väntande inbjudan. Acceptera den för att gå med i ett befintligt hushåll.';

  @override
  String get ssoOnboardingCreateIdentityNote =>
      'Skapa ett nytt användarkonto med din Google-identitet.';

  @override
  String get ssoOnboardingFirstNameRequired => 'Förnamn krävs';

  @override
  String get ssoOnboardingLastNameRequired => 'Efternamn krävs';

  @override
  String get backendConfigTimeout =>
      'Anslutningen tog för lång tid. Kontrollera adressen och försök igen.';

  @override
  String get backendConfigSuccess => 'Anslutningen lyckades!';

  @override
  String backendConfigServerError(int code) {
    return 'Servern svarade med status $code. Kontrollera att det är en Sure-server.';
  }

  @override
  String backendConfigConnectionFailed(String error) {
    return 'Anslutningen misslyckades: $error';
  }

  @override
  String backendConfigSaveFailed(String error) {
    return 'Det gick inte att spara adressen: $error';
  }

  @override
  String get backendConfigUrlRequired => 'Ange en serveradress';

  @override
  String get backendConfigUrlScheme =>
      'Adressen måste börja med http:// eller https://';

  @override
  String get backendConfigUrlInvalid => 'Ange en giltig adress';

  @override
  String get backendConfigHeadersHelp =>
      'Headers skickas av appen med API-anrop. SSO-sidor i extern webbläsare får dem kanske inte.';

  @override
  String get recentTransactionsUnknownAccount => 'Okänt konto';

  @override
  String get accountDetailUnavailable =>
      'Kontouppgifterna är tillfälligt otillgängliga';

  @override
  String chatListMinutesAgo(int minutes) {
    return 'för $minutes min sedan';
  }

  @override
  String chatListHoursAgo(int hours) {
    return 'för $hours tim sedan';
  }

  @override
  String chatListDaysAgo(int days) {
    return 'för $days d sedan';
  }

  @override
  String get chatConversationStartFailed =>
      'Det gick inte att starta konversationen. Försök igen.';

  @override
  String get monthlySpendingTitle => 'Utgifter per månad';

  @override
  String get monthlySpendingPreview => 'Förhandsvisning';

  @override
  String get monthlySpendingFilters => 'Filter';

  @override
  String get monthlySpendingReset => 'Återställ';

  @override
  String get monthlySpendingError =>
      'Det gick inte att läsa utgifterna. Anslut till servern och försök igen.';

  @override
  String get monthlySpendingInvalid =>
      'Välj 1–36 månader i ordning samt tillgängliga konton och kategorier.';

  @override
  String monthlySpendingScope(int accounts, int categories) {
    return '$accounts konton · $categories kategorier';
  }

  @override
  String get monthlySpendingBasis =>
      'Bokförda bruttoutgifter i hushållets valuta. Överföringar och väntande poster ingår inte; återbetalningar räknas som inkomst.';

  @override
  String get monthlySpendingFx =>
      'Preliminärt: valutakurser saknas. Ursprungliga belopp ingår utan omräkning.';

  @override
  String get monthlySpendingEmptySelection =>
      'Välj minst ett konto och en kategori för att visa utgifter.';

  @override
  String get monthlySpendingEmpty =>
      'Inga utgifter att rapportera för detta urval.';

  @override
  String get monthlySpendingChartHidden =>
      'Diagrammet är dolt i integritetsläge.';

  @override
  String get monthlySpendingHint =>
      'Tryck på en stapel för detaljer; svep åt sidan för fler månader. * Pågående månad.';

  @override
  String get monthlySpendingPartial => 'Pågående månad';

  @override
  String get monthlySpendingDetails => 'Månadsdetaljer';

  @override
  String get monthlySpendingFrom => 'Från månad';

  @override
  String get monthlySpendingTo => 'Till månad';

  @override
  String get monthlySpendingAccounts => 'Konton';

  @override
  String get monthlySpendingCategories => 'Kategorier';

  @override
  String get monthlySpendingApply => 'Tillämpa';

  @override
  String get monthlySpendingSearch => 'Sök';

  @override
  String get monthlySpendingAll => 'Alla';

  @override
  String get monthlySpendingNone => 'Inga';

  @override
  String get monthlySpendingNoResults => 'Inga träffar';

  @override
  String get monthlySpendingChooseMonth => 'Välj valfri månad';

  @override
  String get monthlySpendingLastTwelve => 'Senaste 12 månaderna';

  @override
  String get monthlySpendingThisYear => 'Detta år';

  @override
  String get monthlySpendingPreviousYear => 'Föregående år';

  @override
  String get monthlySpendingShowOnHome =>
      'Visa utgifter per månad på startsidan';
}
