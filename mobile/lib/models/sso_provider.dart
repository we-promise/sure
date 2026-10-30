class SsoProvider {
  final String name;
  final String strategy;
  final String label;

  const SsoProvider({
    required this.name,
    required this.strategy,
    required this.label,
  });

  /// Google keeps its brand-compliant "Sign in with Google" button.
  bool get isGoogle => strategy == 'google_oauth2';

  factory SsoProvider.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    return SsoProvider(
      name: name,
      strategy: json['strategy'] as String? ?? '',
      label: json['label'] as String? ?? name,
    );
  }
}
