class TransactionTag {
  final String id;
  final String name;
  final String? color;

  TransactionTag({required this.id, required this.name, this.color});

  factory TransactionTag.fromJson(Map<String, dynamic> json) {
    return TransactionTag(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      color: json['color']?.toString(),
    );
  }
}
