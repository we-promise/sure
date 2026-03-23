import 'package:flutter/foundation.dart' hide Category;
import '../models/category.dart';
import '../services/categories_service.dart';
import '../services/log_service.dart';

class CategoriesProvider with ChangeNotifier {
  final CategoriesService _categoriesService = CategoriesService();
  final LogService _log = LogService.instance;

  List<Category> _categories = [];
  bool _isLoading = false;
  String? _error;
  bool _hasFetched = false;

  List<Category> get categories => List.unmodifiable(_categories);
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasFetched => _hasFetched;

  Future<void> fetchCategories({required String accessToken}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _categoriesService.getCategories(
        accessToken: accessToken,
        perPage: 100,
      );

      if (result['success'] == true) {
        _categories = result['categories'] as List<Category>;
        _hasFetched = true;
        _log.info('CategoriesProvider', 'Fetched ${_categories.length} categories');
      } else {
        _error = result['error'] as String?;
        _log.error('CategoriesProvider', 'Failed to fetch categories: $_error');
      }
    } catch (e) {
      _error = 'Failed to load categories';
      _log.error('CategoriesProvider', 'Exception fetching categories: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clear() {
    _categories = [];
    _hasFetched = false;
    _error = null;
    notifyListeners();
  }
}
