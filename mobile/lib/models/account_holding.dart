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
    final security = json['security'] as Map<String, dynamic>?;

    return AccountHolding(
      id: json['id'].toString(),
      date: JsonParsing.parseRequiredDateTime(json['date'], 'account holding'),
      quantity: json['qty'].toString(),
      price: json['price'] as String,
      amount: json['amount'] as String,
      currency: json['currency'] as String,
      ticker: security?['ticker'] as String?,
      securityName: security?['name'] as String?,
    );
  }
}
