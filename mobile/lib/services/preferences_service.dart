import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _groupByTypeKey = 'dashboard_group_by_type';
  static const _themeModeKey = 'theme_mode';
  static const _biometricEnabledKey = 'biometric_enabled';
  static const _onboardingCompleteKey = 'onboarding_complete';
  static const _userCountryKey = 'user_country';
  static const _consentGivenKey = 'consent_given';
  static const _consentVersionKey = 'consent_version';
  static const _consentDateKey = 'consent_date';

  static PreferencesService? _instance;
  SharedPreferences? _prefs;

  PreferencesService._();

  static PreferencesService get instance {
    _instance ??= PreferencesService._();
    return _instance!;
  }

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<bool> getGroupByType() async {
    final prefs = await _preferences;
    return prefs.getBool(_groupByTypeKey) ?? false;
  }

  Future<void> setGroupByType(bool value) async {
    final prefs = await _preferences;
    await prefs.setBool(_groupByTypeKey, value);
  }

  /// Returns 'light', 'dark', or 'system' (default).
  Future<String> getThemeMode() async {
    final prefs = await _preferences;
    return prefs.getString(_themeModeKey) ?? 'system';
  }

  Future<void> setThemeMode(String mode) async {
    final prefs = await _preferences;
    await prefs.setString(_themeModeKey, mode);
  }

  Future<bool> getBiometricEnabled() async {
    final prefs = await _preferences;
    return prefs.getBool(_biometricEnabledKey) ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await _preferences;
    await prefs.setBool(_biometricEnabledKey, value);
  }

  // Onboarding

  Future<bool> getOnboardingComplete() async {
    final prefs = await _preferences;
    return prefs.getBool(_onboardingCompleteKey) ?? false;
  }

  Future<void> setOnboardingComplete(bool value) async {
    final prefs = await _preferences;
    await prefs.setBool(_onboardingCompleteKey, value);
  }

  // Country

  Future<String> getUserCountry() async {
    final prefs = await _preferences;
    return prefs.getString(_userCountryKey) ?? 'Kenya';
  }

  Future<void> setUserCountry(String country) async {
    final prefs = await _preferences;
    await prefs.setString(_userCountryKey, country);
  }

  // Legal consent

  Future<bool> getConsentGiven() async {
    final prefs = await _preferences;
    return prefs.getBool(_consentGivenKey) ?? false;
  }

  Future<void> setConsent({required String version}) async {
    final prefs = await _preferences;
    await prefs.setBool(_consentGivenKey, true);
    await prefs.setString(_consentVersionKey, version);
    await prefs.setString(_consentDateKey, DateTime.now().toIso8601String());
  }
}
