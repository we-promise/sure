import '../models/merchant.dart';
import 'response_list_parser.dart';

class MerchantsService {
  Future<Map<String, dynamic>> getMerchants({
    required String accessToken,
  }) async {
    return fetchApiList<Merchant>(
      accessToken: accessToken,
      path: '/api/v1/merchants',
      key: 'merchants',
      resultKey: 'merchants',
      fromJson: Merchant.fromJson,
      isValid: (merchant) => merchant.id.isNotEmpty,
      failureMessage: 'Failed to fetch merchants',
    );
  }
}
