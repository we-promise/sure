class Transaction {
  final String? id;
  final String accountId;
  final String name;
  final String date;
  final String amount;
  final String currency;
  final String nature; // "expense" or "income"
  final String? notes;
  final String? categoryId;
  final String? categoryName;

  Transaction({
    this.id,
    required this.accountId,
    required this.name,
    required this.date,
    required this.amount,
    required this.currency,
    required this.nature,
    this.notes,
    this.categoryId,
    this.categoryName,
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

    // Parse category from API response
    String? categoryId;
    String? categoryName;
    if (json['category'] != null && json['category'] is Map) {
      categoryId = json['category']['id']?.toString();
      categoryName = json['category']['name']?.toString();
    } else if (json['category_id'] != null) {
      categoryId = json['category_id']?.toString();
      categoryName = json['category_name']?.toString();
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
      categoryId: categoryId,
      categoryName: categoryName,
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
      if (categoryId != null) 'category_id': categoryId,
      if (categoryName != null) 'category_name': categoryName,
    };
  }

  bool get isExpense => nature == 'expense';
  bool get isIncome => nature == 'income';
}
