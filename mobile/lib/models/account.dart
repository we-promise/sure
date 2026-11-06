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
    return _parseAmount(balance);
  }

  // Parses amounts formatted by any server locale. Handles comma or dot
  // grouping (including Indian lakh/crore) and either decimal separator, so a
  // German or Indian formatted balance never silently becomes zero.
  static double _parseAmount(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^\d.,-]'), '');
    if (cleaned.isEmpty) return 0.0;

    final negative = cleaned.contains('-');
    final digitsAndSeparators = cleaned.replaceAll('-', '');
    if (digitsAndSeparators.isEmpty) return 0.0;

    final lastDot = digitsAndSeparators.lastIndexOf('.');
    final lastComma = digitsAndSeparators.lastIndexOf(',');

    String normalized;
    if (lastDot >= 0 && lastComma >= 0) {
      final decimalIndex = lastDot > lastComma ? lastDot : lastComma;
      final integerPart = digitsAndSeparators
          .substring(0, decimalIndex)
          .replaceAll(RegExp(r'[.,]'), '');
      final fractionPart = digitsAndSeparators
          .substring(decimalIndex + 1)
          .replaceAll(RegExp(r'[.,]'), '');
      normalized = '$integerPart.$fractionPart';
    } else if (lastComma >= 0) {
      final groups = digitsAndSeparators.split(',');
      normalized = _groupsToCanonical(groups);
    } else if (lastDot >= 0) {
      final groups = digitsAndSeparators.split('.');
      normalized = _groupsToCanonical(groups);
    } else {
      normalized = digitsAndSeparators;
    }

    final value = double.tryParse(normalized) ?? 0.0;
    return negative ? -value : value;
  }

  static String _groupsToCanonical(List<String> groups) {
    if (groups.length > 2) return groups.join();

    if (groups.length == 2 && groups[1].length == 3) {
      // A single separator followed by exactly three digits is grouping, not
      // decimals: "1,234" and the German "1.234" both mean one thousand.
      return groups.join();
    }

    if (groups.length == 2) {
      return '${groups[0]}.${groups[1]}';
    }

    return groups.first;
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
