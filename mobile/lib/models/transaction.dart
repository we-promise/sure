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
    return Transaction(
      id: json['id']?.toString(),
      accountId: json['account_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      amount: json['amount']?.toString() ?? '0',
      currency: json['currency']?.toString() ?? '',
      nature: json['nature']?.toString() ?? 'expense',
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
