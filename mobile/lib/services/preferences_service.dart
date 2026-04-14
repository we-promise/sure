import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _groupByTypeKey = 'dashboard_group_by_type';
  static const _biometricEnabledKey = 'biometric_enabled';
  static const _showCategoryFilterKey = 'dashboard_show_category_filter';
  static const _themeModeKey = 'theme_mode';

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

  Future<bool> getBiometricEnabled() async {
    final prefs = await _preferences;
    return prefs.getBool(_biometricEnabledKey) ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await _preferences;
    await prefs.setBool(_biometricEnabledKey, value);
  Future<bool> getShowCategoryFilter() async {
    final prefs = await _preferences;
    return prefs.getBool(_showCategoryFilterKey) ?? false;
  }

  Future<void> setShowCategoryFilter(bool value) async {
    final prefs = await _preferences;
    await prefs.setBool(_showCategoryFilterKey, value);
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
}
