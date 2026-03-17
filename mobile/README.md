# Sure Mobile

A Flutter mobile application for [Sure](https://github.com/we-promise/sure) personal finance management system. This is the mobile client that connects to the Sure backend server.

## About

This app is a mobile companion to the [Sure personal finance management system](https://github.com/we-promise/sure). It provides basic functionality to:

- **Login** - Authenticate with your Sure Finances server
- **View Balance** - See all your accounts and their balances

For more detailed technical documentation, see [docs/TECHNICAL_GUIDE.md](docs/TECHNICAL_GUIDE.md).

## Features

- 🔐 Secure authentication with OAuth 2.0
- 📱 Cross-platform support (Android & iOS)
- 💰 View all linked accounts
- 🎨 Material Design 3 with light/dark theme support
- 🔄 Token refresh for persistent sessions
- 🔒 Two-factor authentication (MFA) support

## Requirements

- Flutter SDK >= 3.0.0
- Dart SDK >= 3.0.0
- Android SDK (for Android builds)
- Xcode (for iOS builds)

## Getting Started

### 1. Install Flutter

Follow the official Flutter installation guide: https://docs.flutter.dev/get-started/install

### 2. Install Dependencies

```bash
flutter pub get

# For iOS development, also install CocoaPods dependencies
cd ios
pod install
cd ..
```

### 3. Generate App Icons

```bash
flutter pub run flutter_launcher_icons
```

This step generates the app icons for all platforms based on the source icon in `assets/icon/app_icon.png`. This is required before building the app locally.

### 4. Configure API Endpoint

Edit `lib/services/api_config.dart` to point to your Sure Finances server:

```dart
// For local development with Android emulator
static String _baseUrl = 'http://10.0.2.2:3000';

// For local development with iOS simulator
static String _baseUrl = 'http://localhost:3000';

// For production
static String _baseUrl = 'https://your-sure-server.com';
```

### 5. Run the App

```bash
# For Android
flutter run -d android

# For iOS
flutter run -d <simulator-device-UDID>
# or
flutter run -d "iPhone 17 Pro"

# For web (development only)
flutter run -d chrome
```

## Project Structure

```
.
├── lib/
│   ├── main.dart              # App entry point
│   ├── models/                # Data models
│   │   ├── account.dart
│   │   ├── auth_tokens.dart
│   │   └── user.dart
│   ├── providers/             # State management
│   │   ├── auth_provider.dart
│   │   └── accounts_provider.dart
│   ├── screens/               # UI screens
│   │   ├── login_screen.dart
│   │   └── dashboard_screen.dart
│   ├── services/              # API services
│   │   ├── api_config.dart
│   │   ├── auth_service.dart
│   │   ├── accounts_service.dart
│   │   └── device_service.dart
│   └── widgets/               # Reusable widgets
│       └── account_card.dart
├── android/                   # Android configuration
├── ios/                       # iOS configuration
├── pubspec.yaml               # Dependencies
└── README.md
```

## API Integration

This app integrates with the Sure Finances Rails API:

### Authentication
- `POST /api/v1/auth/login` - User authentication
- `POST /api/v1/auth/signup` - User registration
- `POST /api/v1/auth/refresh` - Token refresh

### Accounts
- `GET /api/v1/accounts` - Fetch user accounts

### Transactions
- `GET /api/v1/transactions` - Get all transactions (optionally filter by `account_id` query parameter)
- `POST /api/v1/transactions` - Create a new transaction
- `PUT /api/v1/transactions/:id` - Update an existing transaction
- `DELETE /api/v1/transactions/:id` - Delete a transaction

#### Transaction POST Request Format
```json
{
  "transaction": {
    "account_id": "2980ffb0-f595-4572-be0e-7b9b9c53949b",  // required
    "name": "test",  // required
    "date": "2025-07-15",  // required
    "amount": 100,  // optional, defaults to 0
    "currency": "AUD",  // optional, defaults to your profile currency
    "nature": "expense"  // optional, defaults to "expense", other option is "income"
  }
}
```

## CI/CD

The app includes automated CI/CD via GitHub Actions (`.github/workflows/flutter-build.yml`):

- **Triggers**: On push/PR to `main` branch when Flutter files change
- **Android Build**: Generates release APK and AAB artifacts
- **iOS Build**: Generates iOS release build (unsigned)
- **Quality Checks**: Code analysis and tests run before building
- **TestFlight**: `mobile-release` (mobile tags) triggers `.github/workflows/ios-testflight.yml` for signed App Store Connect uploads as part of one release flow

See [mobile/docs/iOS_TESTFLIGHT.md](mobile/docs/iOS_TESTFLIGHT.md) for required secrets and setup.

### Downloading Build Artifacts

After a successful CI run, download artifacts from the GitHub Actions workflow:
- `app-release-apk` - Android APK file
- `app-release-aab` - Android App Bundle (for Play Store)
- `ios-build-unsigned` - iOS app bundle (unsigned, see [iOS build guide](docs/iOS_BUILD.md) for signing)

## Building for Release

### Android

```bash
flutter build apk --release
# or for App Bundle
flutter build appbundle --release
```

### iOS

```bash
# Ensure CocoaPods dependencies are installed first
cd ios && pod install && cd ..

# Build iOS release
flutter build ios --release
```

For detailed iOS build instructions, troubleshooting, and CI/CD setup, see [docs/iOS_BUILD.md](docs/iOS_BUILD.md).

## Future Expansion

This app provides a foundation for additional features:

- Transaction history
- Account sync
- Budget management
- Investment tracking
- AI chat assistant
- Push notifications
- Biometric authentication

## License

This project is distributed under the AGPLv3 license.
