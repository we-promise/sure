/// Application configuration for branding and product identity.
///
/// This follows the same pattern as the Rails app:
/// ```ruby
/// config.x.product_name = ENV.fetch("PRODUCT_NAME", "Sure")
/// config.x.brand_name = ENV.fetch("BRAND_NAME", "FOSS")
/// ```
///
/// In Flutter, compile-time environment variables are accessed via
/// `String.fromEnvironment()`. These can be set during build:
/// ```bash
/// flutter build apk --dart-define=PRODUCT_NAME=MyProduct --dart-define=BRAND_NAME=MyBrand
/// ```
class AppConfig {
  AppConfig._();

  /// The product name displayed throughout the app.
  /// Can be overridden at compile time via --dart-define=PRODUCT_NAME=YourName
  static const String productName = String.fromEnvironment(
    'PRODUCT_NAME',
    defaultValue: 'Sure',
  );

  /// The brand/organization name.
  /// Can be overridden at compile time via --dart-define=BRAND_NAME=YourBrand
  static const String brandName = String.fromEnvironment(
    'BRAND_NAME',
    defaultValue: 'FOSS',
  );

  /// Full application title combining product and brand.
  static String get appTitle => '$productName Finance';

  /// Copyright notice with brand name.
  static String get copyrightNotice => '\u00A9 ${DateTime.now().year} $brandName';
}
