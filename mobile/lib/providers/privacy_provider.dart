import 'package:flutter/foundation.dart';
import '../services/preferences_service.dart';

/// App-wide "privacy mode" toggle. When [hidden] is true, money values are
/// masked across the app (see [MoneyMasker]). The choice is persisted so it
/// survives relaunches, and changes notify listeners so every money widget
/// rebuilds immediately.
class PrivacyProvider extends ChangeNotifier {
  bool _hidden = false;

  /// Whether monetary values should be masked.
  bool get hidden => _hidden;

  PrivacyProvider() {
    _load();
  }

  Future<void> _load() async {
    try {
      _hidden = await PreferencesService.instance.getMoneyHidden();
    } catch (_) {
      _hidden = false;
    }
    notifyListeners();
  }

  /// Sets the masked state and persists it. No-ops if unchanged.
  Future<void> setHidden(bool value) async {
    if (_hidden == value) return;
    _hidden = value;
    notifyListeners();
    await PreferencesService.instance.setMoneyHidden(value);
  }

  /// Flips the masked state.
  Future<void> toggle() => setHidden(!_hidden);
}
