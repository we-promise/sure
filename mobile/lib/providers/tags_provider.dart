import 'package:flutter/foundation.dart';
import '../models/transaction_tag.dart';
import '../services/log_service.dart';
import '../services/tags_service.dart';

class TagsProvider with ChangeNotifier {
  final TagsService _tagsService = TagsService();
  final LogService _log = LogService.instance;

  List<TransactionTag> _tags = [];
  bool _isLoading = false;
  String? _error;
  bool _hasFetched = false;

  List<TransactionTag> get tags => List.unmodifiable(_tags);
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasFetched => _hasFetched;

  Future<void> fetchTags({
    required String accessToken,
    bool forceRefresh = false,
  }) async {
    if (_isLoading || (_hasFetched && !forceRefresh)) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _tagsService.getTags(accessToken: accessToken);

      if (result['success'] == true) {
        _tags = (result['tags'] as List? ?? const []).cast<TransactionTag>();
        _hasFetched = true;
        _log.info('TagsProvider', 'Fetched ${_tags.length} tags');
      } else {
        _error = result['error'] as String?;
        _log.error('TagsProvider', 'Failed to fetch tags: $_error');
      }
    } catch (e) {
      _error = 'Failed to load tags';
      _log.error('TagsProvider', 'Exception fetching tags: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clear() {
    _tags = [];
    _hasFetched = false;
    _error = null;
    notifyListeners();
  }
}
