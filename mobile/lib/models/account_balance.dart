import '../utils/json_parsing.dart';

class AccountBalance {
  final String id;
  final DateTime date;
  final String currency;
  final String balance;
  final int? balanceCents;
  final String? cashBalance;
  final int? cashBalanceCents;

  AccountBalance({
    required this.id,
    required this.date,
    required this.currency,
    required this.balance,
    this.balanceCents,
    this.cashBalance,
    this.cashBalanceCents,
  });

  factory AccountBalance.fromJson(Map<String, dynamic> json) {
    return AccountBalance(
      id: json['id'].toString(),
      date: JsonParsing.parseRequiredDateTime(json['date'], 'account balance'),
      currency: json['currency'] as String,
      balance: json['balance'] as String,
      balanceCents: JsonParsing.parseInt(json['balance_cents']),
      cashBalance: json['cash_balance'] as String?,
      cashBalanceCents: JsonParsing.parseInt(json['cash_balance_cents']),
    );
  }
}
