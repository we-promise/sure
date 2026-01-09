import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'log_service.dart';

class ConnectivityService with ChangeNotifier {
  final Connectivity _connectivity = Connectivity();
  final LogService _log = LogService.instance;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _isOnline = true;
  bool get isOnline => _isOnline;
  bool get isOffline => !_isOnline;

  ConnectivityService() {
    _log.info('ConnectivityService', 'Initializing connectivity service');
    _initConnectivity().then((_) {
      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
    });
  }

  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _log.info('ConnectivityService', 'Initial connectivity check: $result');
      _updateConnectionStatus(result);
    } catch (e) {
      // If we can't determine connectivity, assume we're offline
      _log.error('ConnectivityService', 'Failed to check connectivity: $e');
      _isOnline = false;
      notifyListeners();
    }
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final wasOnline = _isOnline;

    // Check if any result indicates connectivity
    _isOnline = results.any((result) =>
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.ethernet ||
        result == ConnectivityResult.vpn ||
        result == ConnectivityResult.bluetooth);

    _log.info('ConnectivityService', 'Connectivity changed: $results -> ${_isOnline ? "ONLINE" : "OFFLINE"}');

    // Only notify if the status changed
    if (wasOnline != _isOnline) {
      _log.info('ConnectivityService', 'Connection status changed from ${wasOnline ? "ONLINE" : "OFFLINE"} to ${_isOnline ? "ONLINE" : "OFFLINE"}');
      notifyListeners();
    }
  }

  Future<bool> checkConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionStatus(result);
      return _isOnline;
    } catch (e) {
      return false;
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
