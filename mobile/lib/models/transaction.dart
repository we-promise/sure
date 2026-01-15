class Transaction {
  final String? id;
  final String accountId;
  final String name;
  final String date;
  final String amount;
  final String currency;
  final String nature; // "expense" or "income"
  final String? notes;

  Transaction({
    this.id,
    required this.accountId,
    required this.name,
    required this.date,
    required this.amount,
    required this.currency,
    required this.nature,
    this.notes,
  });

  factory Transaction.fromJson(Map<String, dynamic> json) {
    // Handle both API formats:
    // 1. New format: {"account": {"id": "xxx", "name": "..."}}
    // 2. Old format: {"account_id": "xxx"}
    String accountId = '';
    if (json['account'] != null && json['account'] is Map) {
      accountId = json['account']['id']?.toString() ?? '';
    } else if (json['account_id'] != null) {
      accountId = json['account_id']?.toString() ?? '';
    }

    // Handle classification (from backend) or nature (from mobile)
    String nature = 'expense';
    if (json['classification'] != null) {
      final classification = json['classification']?.toString().toLowerCase() ?? '';
      nature = classification == 'income' ? 'income' : 'expense';
    } else if (json['nature'] != null) {
      nature = json['nature']?.toString() ?? 'expense';
    }

    return Transaction(
      id: json['id']?.toString(),
      accountId: accountId,
      name: json['name']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      amount: json['amount']?.toString() ?? '0',
      currency: json['currency']?.toString() ?? '',
      nature: nature,
      notes: json['notes']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'account_id': accountId,
      'name': name,
      'date': date,
      'amount': amount,
      'currency': currency,
      'nature': nature,
      if (notes != null) 'notes': notes,
    };
  }

  bool get isExpense => nature == 'expense';
  bool get isIncome => nature == 'income';
}
