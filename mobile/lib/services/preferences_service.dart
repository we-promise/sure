import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _groupByTypeKey = 'dashboard_group_by_type';

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
}
