import 'package:sure_mobile/models/category.dart';
import 'package:sure_mobile/services/categories_service.dart';

/// Answers `GET /api/v1/categories` lookups without the network.
class FakeCategoriesService extends CategoriesService {
  FakeCategoriesService({
    this.subcategories = const [],
    this.response,
  });

  /// Returned as the subcategories of any parent.
  final List<Category> subcategories;

  /// Returned instead of [subcategories] when set (e.g. a failure).
  final Map<String, dynamic>? response;

  final List<String?> parentIds = [];

  @override
  Future<Map<String, dynamic>> getCategories({
    required String accessToken,
    int? page,
    int? perPage,
    bool? rootsOnly,
    String? parentId,
  }) async {
    parentIds.add(parentId);
    return response ?? {'success': true, 'categories': subcategories};
  }
}
