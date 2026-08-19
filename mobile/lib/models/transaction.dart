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
  final bool categoryProvided;
  final String? merchantId;
  final String? merchantName;
  final bool merchantProvided;
  final List<String> tagIds;
  final List<String> tagNames;
  final bool tagsProvided;

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
    bool? categoryProvided,
    this.merchantId,
    this.merchantName,
    bool? merchantProvided,
    List<String> tagIds = const [],
    List<String> tagNames = const [],
    bool? tagsProvided,
  })  : tagIds = List.unmodifiable(tagIds),
        tagNames = List.unmodifiable(tagNames),
        categoryProvided =
            categoryProvided ?? (categoryId != null || categoryName != null),
        merchantProvided =
            merchantProvided ?? (merchantId != null || merchantName != null),
        tagsProvided =
            tagsProvided ?? (tagIds.isNotEmpty || tagNames.isNotEmpty);

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
      final classification =
          json['classification']?.toString().toLowerCase() ?? '';
      nature = classification == 'income' ? 'income' : 'expense';
    } else if (json['nature'] != null) {
      nature = json['nature']?.toString() ?? 'expense';
    }

    // Parse category from API response
    String? categoryId;
    String? categoryName;
    final categoryProvided = json.containsKey('category') ||
        json.containsKey('category_id') ||
        json.containsKey('category_name');
    if (json['category'] != null && json['category'] is Map) {
      categoryId = json['category']['id']?.toString();
      categoryName = json['category']['name']?.toString();
    } else if (json['category_id'] != null) {
      categoryId = json['category_id']?.toString();
      categoryName = json['category_name']?.toString();
    }

    String? merchantId;
    String? merchantName;
    final merchantProvided = json.containsKey('merchant') ||
        json.containsKey('merchant_id') ||
        json.containsKey('merchant_name');
    if (json['merchant'] != null && json['merchant'] is Map) {
      merchantId = json['merchant']['id']?.toString();
      merchantName = json['merchant']['name']?.toString();
    } else if (json['merchant_id'] != null) {
      merchantId = json['merchant_id']?.toString();
      merchantName = json['merchant_name']?.toString();
    }

    final tagIds = <String>[];
    final tagNames = <String>[];
    final tagsProvided = json.containsKey('tags') ||
        json.containsKey('tag_ids') ||
        json.containsKey('tag_names');
    if (json['tags'] is List) {
      for (final tag in json['tags']) {
        if (tag is Map) {
          final id = tag['id']?.toString().trim();
          if (id != null && id.isNotEmpty) {
            tagIds.add(id);
            tagNames.add(tag['name']?.toString() ?? '');
          }
        }
      }
    } else if (json['tag_ids'] is List) {
      final rawIds = json['tag_ids'] as List;
      final rawNames =
          json['tag_names'] is List ? json['tag_names'] as List : const [];
      for (var i = 0; i < rawIds.length; i++) {
        final id = rawIds[i]?.toString().trim() ?? '';
        if (id.isNotEmpty) {
          tagIds.add(id);
          tagNames
              .add(i < rawNames.length ? rawNames[i]?.toString() ?? '' : '');
        }
      }
    }
    while (tagNames.length < tagIds.length) {
      tagNames.add('');
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
      categoryProvided: categoryProvided,
      merchantId: merchantId,
      merchantName: merchantName,
      merchantProvided: merchantProvided,
      tagIds: tagIds,
      tagNames: tagNames,
      tagsProvided: tagsProvided,
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
      if (merchantId != null) 'merchant_id': merchantId,
      if (merchantName != null) 'merchant_name': merchantName,
      if (tagIds.isNotEmpty) 'tag_ids': tagIds,
      if (tagNames.isNotEmpty) 'tag_names': tagNames,
    };
  }

  bool get isExpense => nature == 'expense';
  bool get isIncome => nature == 'income';
}
