import 'package:flutter/foundation.dart';

import '../models/transaction_split.dart';
import '../services/connectivity_service.dart';
import '../services/log_service.dart';
import '../services/transaction_splits_service.dart';

/// Outcome of a split write (create, replace, or unsplit).
class SplitActionResult {
  final bool success;
  final TransactionSplit? split;
  final String? error;

  /// Server ids of children that no longer exist after this action. Callers
  /// drop them from the offline cache, since an account-scoped sync only
  /// upserts and would otherwise leave them behind.
  final List<String> removedChildIds;

  const SplitActionResult({
    required this.success,
    this.split,
    this.error,
    this.removedChildIds = const [],
  });
}

/// Loads and edits transaction splits, and remembers the split structure it
/// has seen so the transaction list can group children under their parent.
///
/// Splits are online-only: the offline queue only replays creates and
/// deletes, so writes are refused while offline instead of being queued.
class TransactionSplitsProvider with ChangeNotifier {
  TransactionSplitsProvider({TransactionSplitsService? service})
      : _service = service ?? TransactionSplitsService();

  final TransactionSplitsService _service;
  final LogService _log = LogService.instance;

  final Map<String, TransactionSplit> _splitsByParent = {};
  final Map<String, String> _parentByChild = {};
  final Set<String> _loading = {};
  ConnectivityService? _connectivityService;
  bool _isDisposed = false;

  static const offlineError = 'offline';

  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
  }

  bool get isOnline => _connectivityService?.isOnline ?? true;

  bool isLoading(String transactionId) => _loading.contains(transactionId);

  /// The split [transactionId] belongs to, as parent or child, if known.
  TransactionSplit? splitFor(String transactionId) {
    final direct = _splitsByParent[transactionId];
    if (direct != null) return direct;
    final parentId = _parentByChild[transactionId];
    return parentId == null ? null : _splitsByParent[parentId];
  }

  bool isSplitParent(String transactionId) =>
      _splitsByParent.containsKey(transactionId);

  bool isSplitChild(String transactionId) =>
      _parentByChild.containsKey(transactionId);

  String? parentIdFor(String childId) => _parentByChild[childId];

  String? _lastError;

  /// Why the last [loadSplit] could not reach the server, or null. Equals
  /// [offlineError] when the device is offline.
  String? get lastError => _lastError;

  /// Fetches the split for [transactionId]. Returns null when it is not split.
  /// When the request fails, the cached split (if any) is returned and
  /// [lastError] says why.
  Future<TransactionSplit?> loadSplit({
    required String accessToken,
    required String transactionId,
  }) async {
    if (!isOnline) {
      _lastError = offlineError;
      return splitFor(transactionId);
    }

    _loading.add(transactionId);
    _lastError = null;
    _notify();

    try {
      final result = await _service.getSplit(
        accessToken: accessToken,
        transactionId: transactionId,
      );
      if (result['success'] == true) {
        final split = result['split'] as TransactionSplit?;
        if (split == null) {
          _forget(transactionId);
        } else {
          _remember(split);
        }
        return split;
      }
      _lastError = result['error'] as String?;
      return splitFor(transactionId);
    } catch (e) {
      _log.error(
        'TransactionSplitsProvider',
        'loadSplit failed with ${e.runtimeType}',
      );
      _lastError = 'Something went wrong. Please try again.';
      return splitFor(transactionId);
    } finally {
      _loading.remove(transactionId);
      _notify();
    }
  }

  /// Creates a split, or replaces the existing one when [replace] is true.
  Future<SplitActionResult> saveSplit({
    required String accessToken,
    required String transactionId,
    required List<SplitRowInput> rows,
    required bool replace,
  }) async {
    if (!isOnline) {
      return const SplitActionResult(success: false, error: offlineError);
    }

    final previous = splitFor(transactionId);
    try {
      final result = replace
          ? await _service.updateSplit(
              accessToken: accessToken,
              transactionId: transactionId,
              rows: rows,
            )
          : await _service.createSplit(
              accessToken: accessToken,
              transactionId: transactionId,
              rows: rows,
            );

      if (result['success'] != true) {
        return SplitActionResult(
          success: false,
          error: result['error'] as String?,
        );
      }

      final split = result['split'] as TransactionSplit;
      final newIds = split.childIds.toSet();
      final removed = (previous?.childIds ?? const <String>[])
          .where((id) => !newIds.contains(id))
          .toList();
      if (previous != null) _forget(previous.transactionId);
      _remember(split);
      _notify();
      return SplitActionResult(
        success: true,
        split: split,
        removedChildIds: removed,
      );
    } catch (e) {
      _log.error(
        'TransactionSplitsProvider',
        'saveSplit failed with ${e.runtimeType}',
      );
      return const SplitActionResult(
        success: false,
        error: 'Something went wrong. Please try again.',
      );
    }
  }

  /// Removes the split [transactionId] belongs to.
  Future<SplitActionResult> unsplit({
    required String accessToken,
    required String transactionId,
  }) async {
    if (!isOnline) {
      return const SplitActionResult(success: false, error: offlineError);
    }

    final previous = splitFor(transactionId);
    try {
      final result = await _service.deleteSplit(
        accessToken: accessToken,
        transactionId: transactionId,
      );
      if (result['success'] != true) {
        return SplitActionResult(
          success: false,
          error: result['error'] as String?,
        );
      }

      if (previous != null) _forget(previous.transactionId);
      _forget(transactionId);
      _notify();
      return SplitActionResult(
        success: true,
        removedChildIds: previous?.childIds ?? const [],
      );
    } catch (e) {
      _log.error(
        'TransactionSplitsProvider',
        'unsplit failed with ${e.runtimeType}',
      );
      return const SplitActionResult(
        success: false,
        error: 'Something went wrong. Please try again.',
      );
    }
  }

  /// Seeds the cache directly (used by tests and after a successful write).
  @visibleForTesting
  void remember(TransactionSplit split) {
    _remember(split);
    _notify();
  }

  void clear() {
    _splitsByParent.clear();
    _parentByChild.clear();
    _notify();
  }

  void _remember(TransactionSplit split) {
    _forget(split.transactionId);
    _splitsByParent[split.transactionId] = split;
    for (final childId in split.childIds) {
      _parentByChild[childId] = split.transactionId;
    }
  }

  void _forget(String transactionId) {
    final parentId = _parentByChild[transactionId] ?? transactionId;
    final split = _splitsByParent.remove(parentId);
    if (split != null) {
      for (final childId in split.childIds) {
        _parentByChild.remove(childId);
      }
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
