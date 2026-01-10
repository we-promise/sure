class Account {
  final String id;
  final String name;
  final String balance;
  final String currency;
  final String? classification;
  final String accountType;

  Account({
    required this.id,
    required this.name,
    required this.balance,
    required this.currency,
    this.classification,
    required this.accountType,
  });

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'].toString(),
      name: json['name'] as String,
      balance: json['balance'] as String,
      currency: json['currency'] as String,
      classification: json['classification'] as String?,
      accountType: json['account_type'] as String,
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
