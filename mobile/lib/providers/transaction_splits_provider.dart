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

/// Whether a transaction may be deleted like a plain one, as far as splits go.
enum SplitDeleteStatus {
  /// Not split (confirmed by the server, or offline with nothing cached).
  allowed,

  /// A split parent or child: it has to be unsplit first.
  split,

  /// Online, but the split lookup failed, so deleting could cascade to
  /// children this device does not know about.
  unknown,
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

  /// Transactions whose split membership (parent, child, or not split) has
  /// been confirmed by the server in this session.
  final Set<String> _known = {};
  final Set<String> _failedLookups = {};
  final Set<String> _loading = {};
  ConnectivityService? _connectivityService;
  bool _isDisposed = false;

  /// Bumped by [clear]. Requests that started before a clear must not write
  /// their result back into the reset cache.
  int _generation = 0;

  static const offlineError = 'offline';

  /// Follows [service] so split widgets rebuild when connectivity changes;
  /// the proxy provider keeps this instance, so nothing else notifies them.
  void setConnectivityService(ConnectivityService service) {
    if (identical(service, _connectivityService)) return;
    _connectivityService?.removeListener(_onConnectivityChanged);
    _connectivityService = service;
    service.addListener(_onConnectivityChanged);
  }

  void _onConnectivityChanged() => _notify();

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

  /// Whether the server has confirmed if [transactionId] is a split parent,
  /// a split child, or not split. Until then, edits that the API rejects for
  /// split children must stay locked.
  bool isSplitStatusKnown(String transactionId) =>
      _known.contains(transactionId);

  /// Whether the edit form may be used: the split status is known, or its
  /// lookup failed (the server still rejects direct edits of split children).
  bool canEditAfterLookup(String transactionId) =>
      _known.contains(transactionId) || _failedLookups.contains(transactionId);

  String? parentIdFor(String childId) => _parentByChild[childId];

  String? _lastError;

  /// Why the last [loadSplit] could not reach the server, or null. Equals
  /// [offlineError] when the device is offline.
  String? get lastError => _lastError;

  /// Fetches the split for [transactionId]. Returns null when it is not split.
  /// When the request fails, the cached split (if any) is returned and
  /// [lastError] says why.
  /// A failed lookup must not lock editing of an ordinary transaction: let
  /// the user proceed, since the server still rejects direct edits of split
  /// children. Only transactions with no cached split are unlocked, and the
  /// lookup is retried the next time the screen loads.
  void _allowEditingAfterFailedLookup(String transactionId) {
    if (splitFor(transactionId) == null) _failedLookups.add(transactionId);
  }

  Future<TransactionSplit?> loadSplit({
    required String accessToken,
    required String transactionId,
  }) async {
    await _lookup(accessToken: accessToken, transactionId: transactionId);
    return splitFor(transactionId);
  }

  /// Asks the server for [transactionId]'s split membership and records it.
  /// Returns true only when the server answered.
  Future<bool> _lookup({
    required String accessToken,
    required String transactionId,
  }) async {
    if (!isOnline) {
      _lastError = offlineError;
      return false;
    }

    final generation = _generation;
    _loading.add(transactionId);
    _lastError = null;
    _notify();

    try {
      final result = await _service.getSplit(
        accessToken: accessToken,
        transactionId: transactionId,
      );
      if (generation != _generation) return false;
      if (result['success'] == true) {
        final split = result['split'] as TransactionSplit?;
        if (split == null) {
          _forget(transactionId);
        } else {
          _remember(split);
        }
        _known.add(transactionId);
        _failedLookups.remove(transactionId);
        return true;
      }
      _lastError = result['error'] as String?;
      _allowEditingAfterFailedLookup(transactionId);
      return false;
    } catch (e) {
      _log.error(
        'TransactionSplitsProvider',
        'loadSplit failed with ${e.runtimeType}',
      );
      if (generation != _generation) return false;
      _lastError = 'Something went wrong. Please try again.';
      _allowEditingAfterFailedLookup(transactionId);
      return false;
    } finally {
      _loading.remove(transactionId);
      _notify();
    }
  }

  /// Decides whether [transactionId] may go through the plain delete
  /// endpoint. The server refuses a split child and cascades a split parent's
  /// delete to its children, which an upsert-only sync would leave behind.
  ///
  /// Online, membership is looked up first: always when [fresh] is true (the
  /// row may have been split on the web or another device since it was last
  /// seen), otherwise only when it is not known yet. A failed lookup returns
  /// [SplitDeleteStatus.unknown] so the caller blocks the delete. Offline,
  /// only splits already known on this device are blocked, so offline delete
  /// keeps working; the transactions index does not say which rows are split.
  Future<SplitDeleteStatus> checkBeforeDelete({
    required String? accessToken,
    required String transactionId,
    bool fresh = false,
  }) async {
    if (isOnline && (fresh || !_known.contains(transactionId))) {
      if (accessToken == null) return SplitDeleteStatus.unknown;
      final ok = await _lookup(
        accessToken: accessToken,
        transactionId: transactionId,
      );
      if (!ok) return SplitDeleteStatus.unknown;
    }
    if (isSplitParent(transactionId) || isSplitChild(transactionId)) {
      return SplitDeleteStatus.split;
    }
    return SplitDeleteStatus.allowed;
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
    final generation = _generation;
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
          error: _displayableError(result['error'] as String?, 'saveSplit'),
        );
      }

      final split = result['split'] as TransactionSplit;
      final newIds = split.childIds.toSet();
      final removed = (previous?.childIds ?? const <String>[])
          .where((id) => !newIds.contains(id))
          .toList();
      if (generation == _generation) {
        if (previous != null) _forget(previous.transactionId);
        _remember(split);
        _notify();
      }
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
      return const SplitActionResult(success: false);
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
    final generation = _generation;
    try {
      final result = await _service.deleteSplit(
        accessToken: accessToken,
        transactionId: transactionId,
      );
      if (result['success'] != true) {
        return SplitActionResult(
          success: false,
          error: _displayableError(result['error'] as String?, 'unsplit'),
        );
      }

      if (generation == _generation) {
        if (previous != null) _forget(previous.transactionId);
        _forget(transactionId);
        _notify();
      }
      return SplitActionResult(
        success: true,
        removedChildIds: previous?.childIds ?? const [],
      );
    } catch (e) {
      _log.error(
        'TransactionSplitsProvider',
        'unsplit failed with ${e.runtimeType}',
      );
      return const SplitActionResult(success: false);
    }
  }

  /// Seeds the cache directly (used by tests and after a successful write).
  @visibleForTesting
  void remember(TransactionSplit split) {
    _remember(split);
    _notify();
  }

  /// Drops everything this provider learned (sign-out, clearing local
  /// data). Lookups and writes still in flight finish without repopulating it.
  void clear() {
    _generation++;
    _loading.clear();
    _splitsByParent.clear();
    _parentByChild.clear();
    _known.clear();
    _failedLookups.clear();
    _notify();
  }

  /// Server validation messages are shown as they are. Session and transport
  /// failures are logged and returned as null, so screens show their own
  /// localized failure message instead.
  String? _displayableError(String? error, String operation) {
    if (error == null ||
        error == 'unauthorized' ||
        error.startsWith('Network error:')) {
      _log.error(
        'TransactionSplitsProvider',
        '$operation failed: ${error ?? 'no error message'}',
      );
      return null;
    }
    return error;
  }

  void _remember(TransactionSplit split) {
    _forget(split.transactionId);
    _splitsByParent[split.transactionId] = split;
    _known.add(split.transactionId);
    for (final childId in split.childIds) {
      _parentByChild[childId] = split.transactionId;
      _known.add(childId);
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
    _connectivityService?.removeListener(_onConnectivityChanged);
    _connectivityService = null;
    super.dispose();
  }
}
