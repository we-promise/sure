import 'package:flutter/foundation.dart';
import '../models/merchant.dart';
import '../services/log_service.dart';
import '../services/merchants_service.dart';

class MerchantsProvider with ChangeNotifier {
  final MerchantsService _merchantsService = MerchantsService();
  final LogService _log = LogService.instance;

  List<Merchant> _merchants = [];
  bool _isLoading = false;
  String? _error;
  bool _hasFetched = false;

  List<Merchant> get merchants => List.unmodifiable(_merchants);
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasFetched => _hasFetched;

  Future<void> fetchMerchants({
    required String accessToken,
    bool forceRefresh = false,
  }) async {
    if (_isLoading || (_hasFetched && !forceRefresh)) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _merchantsService.getMerchants(
        accessToken: accessToken,
      );

      if (result['success'] == true) {
        _merchants =
            (result['merchants'] as List? ?? const []).cast<Merchant>();
        _hasFetched = true;
        _log.info(
          'MerchantsProvider',
          'Fetched ${_merchants.length} merchants',
        );
      } else {
        _error = result['error'] as String?;
        _log.error('MerchantsProvider', 'Failed to fetch merchants: $_error');
      }
    } catch (e) {
      _error = 'Failed to load merchants';
      _log.error('MerchantsProvider', 'Exception fetching merchants: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clear() {
    _merchants = [];
    _hasFetched = false;
    _error = null;
    notifyListeners();
  }
}
