class Category {
  final String id;
  final String name;
  final String? color;
  final String? icon;
  final Category? parent;
  final int subcategoriesCount;

  Category({
    required this.id,
    required this.name,
    this.color,
    this.icon,
    this.parent,
    this.subcategoriesCount = 0,
  });

  factory Category.fromJson(Map<String, dynamic> json) {
    Category? parent;
    if (json['parent'] != null && json['parent'] is Map) {
      parent = Category.fromJson(Map<String, dynamic>.from(json['parent']));
    }

    return Category(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      color: json['color']?.toString(),
      icon: json['icon']?.toString(),
      parent: parent,
      subcategoriesCount: json['subcategories_count'] as int? ?? 0,
    );
  }

  /// Display name including full ancestor path for subcategories
  String get displayName {
    final parts = <String>[];
    Category? current = this;
    while (current != null) {
      parts.add(current.name);
      current = current.parent;
    }
    return parts.reversed.join(' > ');
  }
}
