import '../utils/json_parsing.dart';

class AccountHolding {
  final String id;
  final DateTime date;
  final String quantity;
  final String price;
  final String amount;
  final String currency;
  final String? ticker;
  final String? securityName;

  AccountHolding({
    required this.id,
    required this.date,
    required this.quantity,
    required this.price,
    required this.amount,
    required this.currency,
    this.ticker,
    this.securityName,
  });

  factory AccountHolding.fromJson(Map<String, dynamic> json) {
    final securityJson = json['security'];
    final security = securityJson is Map<String, dynamic> ? securityJson : null;

    return AccountHolding(
      id: json['id'].toString(),
      date: JsonParsing.parseRequiredDateTime(json['date'], 'account holding'),
      quantity: JsonParsing.parseRequiredString(
        json['qty'],
        'account holding quantity',
      ),
      price: JsonParsing.parseRequiredString(
        json['price'],
        'account holding price',
      ),
      amount: JsonParsing.parseRequiredString(
        json['amount'],
        'account holding amount',
      ),
      currency: JsonParsing.parseRequiredString(
        json['currency'],
        'account holding currency',
      ),
      ticker: JsonParsing.parseString(security?['ticker']),
      securityName: JsonParsing.parseString(security?['name']),
    );
  }
}
