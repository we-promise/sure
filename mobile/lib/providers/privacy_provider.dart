import 'package:flutter/foundation.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';

/// App-wide "privacy mode" toggle. When [hidden] is true, money values are
/// masked across the app (see [MoneyMasker]). The choice is persisted so it
/// survives relaunches, and changes notify listeners so every money widget
/// rebuilds immediately.
///
/// The preference is read before `runApp` and passed in as [initialHidden], so
/// the very first build already has the correct value — no startup window where
/// balances could flash. When [initialHidden] is omitted (e.g. in tests) the
/// provider starts masked (fail-closed) and hydrates asynchronously, so a user
/// who had privacy mode on still never flashes their balances.
class PrivacyProvider extends ChangeNotifier {
  // Fail closed: assume masked until the stored preference is known.
  bool _hidden;

  // Set once the user explicitly toggles, so a late-completing initial load
  // can't clobber their choice (see _load).
  bool _userOverrode = false;

  /// Whether monetary values should be masked.
  bool get hidden => _hidden;

  PrivacyProvider({bool? initialHidden}) : _hidden = initialHidden ?? true {
    if (initialHidden == null) {
      _load();
    }
  }

  Future<void> _load() async {
    bool? stored;
    try {
      stored = await PreferencesService.instance.getMoneyHidden();
    } catch (e) {
      // Keep the fail-closed default (masked) if the preference can't be read.
      LogService.instance.warning(
        'PrivacyProvider',
        'Failed to load privacy preference with ${e.runtimeType}',
      );
    }
    // Only apply the loaded value if the user hasn't toggled in the meantime,
    // so the initial hydration never overwrites an explicit choice.
    if (!_userOverrode && stored != null) {
      _hidden = stored;
    }
    notifyListeners();
  }

  /// Sets the masked state and persists it. No-ops if unchanged. If persistence
  /// fails the in-memory state is reverted so the UI stays consistent with what
  /// is actually stored.
  Future<void> setHidden(bool value) async {
    _userOverrode = true;
    if (_hidden == value) return;
    final previous = _hidden;
    _hidden = value;
    notifyListeners();
    try {
      await PreferencesService.instance.setMoneyHidden(value);
    } catch (e) {
      _hidden = previous;
      notifyListeners();
      LogService.instance.warning(
        'PrivacyProvider',
        'Failed to persist privacy preference with ${e.runtimeType}',
      );
    }
  }

  /// Flips the masked state.
  Future<void> toggle() => setHidden(!_hidden);
}
