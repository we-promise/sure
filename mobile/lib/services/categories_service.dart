import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/category.dart';
import 'api_config.dart';

class CategoriesService {
  Future<Map<String, dynamic>> getCategories({
    required String accessToken,
    int? page,
    int? perPage,
    bool? rootsOnly,
    String? parentId,
  }) async {
    final Map<String, String> queryParams = {};

    if (page != null) {
      queryParams['page'] = page.toString();
    }
    if (perPage != null) {
      queryParams['per_page'] = perPage.toString();
    }
    if (rootsOnly == true) {
      queryParams['roots_only'] = 'true';
    }
    if (parentId != null) {
      queryParams['parent_id'] = parentId;
    }

    final baseUri = Uri.parse('${ApiConfig.baseUrl}/api/v1/categories');
    final url = queryParams.isNotEmpty
        ? baseUri.replace(queryParameters: queryParams)
        : baseUri;

    try {
      final response = await http.get(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        List<dynamic> categoriesJson;
        if (responseData is List) {
          categoriesJson = responseData;
        } else if (responseData is Map && responseData.containsKey('categories')) {
          categoriesJson = responseData['categories'];
        } else {
          categoriesJson = [];
        }

        final categories = categoriesJson
            .map((json) => Category.fromJson(json))
            .toList();

        return {
          'success': true,
          'categories': categories,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to fetch categories',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }
}
