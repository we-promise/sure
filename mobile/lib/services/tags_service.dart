import '../models/transaction_tag.dart';
import 'response_list_parser.dart';

class TagsService {
  Future<Map<String, dynamic>> getTags({required String accessToken}) async {
    return fetchApiList<TransactionTag>(
      accessToken: accessToken,
      path: '/api/v1/tags',
      key: 'tags',
      resultKey: 'tags',
      fromJson: TransactionTag.fromJson,
      isValid: (tag) => tag.id.isNotEmpty,
      failureMessage: 'Failed to fetch tags',
    );
  }
}
