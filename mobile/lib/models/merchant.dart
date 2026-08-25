class Merchant {
  final String id;
  final String name;
  final String? type;

  Merchant({required this.id, required this.name, this.type});

  factory Merchant.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      throw FormatException('Merchant response is missing id: $json');
    }

    return Merchant(
      id: id,
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString(),
    );
  }
}
