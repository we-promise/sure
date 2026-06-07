import '../utils/json_parsing.dart';

class Account {
  final String id;
  final String name;
  final String balance;
  final int? balanceCents;
  final String? cashBalance;
  final int? cashBalanceCents;
  final String currency;
  final String? classification;
  final String accountType;
  final String? subtype;
  final String? status;
  final String? institutionName;
  final String? institutionDomain;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Account({
    required this.id,
    required this.name,
    required this.balance,
    this.balanceCents,
    this.cashBalance,
    this.cashBalanceCents,
    required this.currency,
    this.classification,
    required this.accountType,
    this.subtype,
    this.status,
    this.institutionName,
    this.institutionDomain,
    this.createdAt,
    this.updatedAt,
  });

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'].toString(),
      name: JsonParsing.parseRequiredString(json['name'], 'account name'),
      balance: JsonParsing.parseRequiredString(
        json['balance'],
        'account balance',
      ),
      balanceCents: JsonParsing.parseInt(json['balance_cents']),
      cashBalance: JsonParsing.parseString(json['cash_balance']),
      cashBalanceCents: JsonParsing.parseInt(json['cash_balance_cents']),
      currency: JsonParsing.parseRequiredString(
        json['currency'],
        'account currency',
      ),
      classification: JsonParsing.parseString(json['classification']),
      accountType: JsonParsing.parseRequiredString(
        json['account_type'],
        'account type',
      ),
      subtype: JsonParsing.parseString(json['subtype']),
      status: JsonParsing.parseString(json['status']),
      institutionName: JsonParsing.parseString(json['institution_name']),
      institutionDomain: JsonParsing.parseString(json['institution_domain']),
      createdAt: JsonParsing.parseDateTime(json['created_at']),
      updatedAt: JsonParsing.parseDateTime(json['updated_at']),
    );
  }

  bool get isAsset => classification == 'asset';
  bool get isLiability => classification == 'liability';

  double get balanceAsDouble {
    try {
      // Remove commas and any other non-numeric characters except dots and minus signs
      final cleanedBalance = balance.replaceAll(RegExp(r'[^\d.-]'), '');
      return double.parse(cleanedBalance);
    } catch (e) {
      return 0.0;
    }
  }

  String get displayAccountType {
    switch (accountType) {
      case 'depository':
        return 'Bank Account';
      case 'credit_card':
        return 'Credit Card';
      case 'investment':
        return 'Investment';
      case 'loan':
        return 'Loan';
      case 'property':
        return 'Property';
      case 'vehicle':
        return 'Vehicle';
      case 'crypto':
        return 'Crypto';
      case 'other_asset':
        return 'Other Asset';
      case 'other_liability':
        return 'Other Liability';
      default:
        return accountType;
    }
  }
}
