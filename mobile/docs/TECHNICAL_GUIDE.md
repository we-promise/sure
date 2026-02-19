# Sure Flutter - Technical Documentation

## Project Overview

Sure Flutter is a mobile client for the [Sure Finances Management System](https://github.com/we-promise/sure), developed with Flutter framework and supporting both Android and iOS platforms. This application provides core mobile functionality for the Sure Finances management system, allowing users to view and manage their financial accounts anytime, anywhere.

### Backend Relationship

This application is a client app for the Sure Finances Management System and requires connection to the Sure backend server (Rails API) to function properly. Backend project: https://github.com/we-promise/sure

## Core Features

### 1. Backend Configuration
- **Server Address Configuration**: Configure Sure backend server URL on first launch
- **Connection Testing**: Provides connection test functionality to verify server availability
- **Address Persistence**: Server address is saved locally and automatically loaded on next startup

### 2. User Authentication
- **Login**: Support email and password login
- **Two-Factor Authentication (MFA)**: Support OTP verification code secondary verification
- **User Registration**: Support new user registration (backend supported)
- **Token Management**:
  - Access Token for API request authentication
  - Refresh Token for refreshing expired Access Tokens
  - Tokens securely stored in device's secure storage
- **Auto-login**: Automatically checks local tokens on app startup and logs in if valid
- **Device Information Tracking**: Records device information on login for backend session management

### 3. Account Management
- **Account List Display**: Shows all user financial accounts
- **Account Classification**:
  - **Asset Accounts**: Bank accounts, investment accounts, cryptocurrency, real estate, vehicles, etc.
  - **Liability Accounts**: Credit cards, loans, etc.
  - **Other Accounts**: Uncategorized accounts
- **Account Type Support**:
  - Depository
  - Credit Card
  - Investment
  - Loan
  - Property
  - Vehicle
  - Crypto
  - Other assets/liabilities
- **Balance Display**: Shows current balance and currency type for each account
- **Pull to Refresh**: Supports pull-to-refresh for account data

## Technical Architecture

### Tech Stack
- **Framework**: Flutter 3.0+
- **Language**: Dart 3.0+
- **State Management**: Provider
- **Network Requests**: http
- **Local Storage**:
  - shared_preferences (non-sensitive data, like server URL)
  - flutter_secure_storage (sensitive data, like tokens)

### Project Structure

```
lib/
├── main.dart                      # App entry point
├── models/                        # Data models
│   ├── account.dart              # Account model
│   ├── auth_tokens.dart          # Authentication token model
│   └── user.dart                 # User model
├── providers/                     # State management
│   ├── auth_provider.dart        # Authentication state management
│   └── accounts_provider.dart    # Accounts state management
├── screens/                       # Screens
│   ├── backend_config_screen.dart # Backend configuration screen
│   ├── login_screen.dart         # Login screen
│   └── dashboard_screen.dart     # Main screen (account list)
├── services/                      # Business services
│   ├── api_config.dart           # API configuration
│   ├── auth_service.dart         # Authentication service
│   ├── accounts_service.dart     # Accounts service
│   └── device_service.dart       # Device information service
└── widgets/                       # Reusable widgets
    └── account_card.dart         # Account card widget
```

## Application Flow Details

### Startup Flow

```
App Launch
    ↓
Initialize ApiConfig (load saved backend URL)
    ↓
Check if backend URL is configured
    ├─ No → Show backend configuration screen
    │         ↓
    │       Enter and test URL
    │         ↓
    │       Save configuration
    │         ↓
    └─ Yes → Check Token
            ├─ Invalid or not exists → Show login screen
            │                           ↓
            │                         User login
            │                           ↓
            │                         Save tokens and user info
            │                           ↓
            └─ Valid → Enter Dashboard
```

### Authentication Flow

#### 1. Login Flow (login_screen.dart)

```
User enters email and password
    ↓
Click login button
    ↓
AuthProvider.login()
    ↓
Collect device information (DeviceService)
    ↓
Call AuthService.login()
    ↓
Send POST /api/v1/auth/login
    ├─ Success (200)
    │   ↓
    │  Save Access Token and Refresh Token
    │   ↓
    │  Save user information
    │   ↓
    │  Navigate to dashboard
    │
    ├─ MFA Required (401 + mfa_required)
    │   ↓
    │  Show OTP input field
    │   ↓
    │  User enters verification code
    │   ↓
    │  Re-login (with OTP)
    │
    └─ Failure
        ↓
       Show error message
```

#### 2. Token Refresh Flow (auth_provider.dart)

```
Need to access API
    ↓
Check if Access Token is expired
    ├─ Not expired → Use directly
    │
    └─ Expired
        ↓
       Get Refresh Token
        ↓
       Call AuthService.refreshToken()
        ↓
       Send POST /api/v1/auth/refresh
        ├─ Success
        │   ↓
        │  Save new tokens
        │   ↓
        │  Return new Access Token
        │
        └─ Failure
            ↓
           Clear tokens
            ↓
           Return to login screen
```

### Account Data Flow

#### 1. Fetch Account List (dashboard_screen.dart)

```
Enter dashboard
    ↓
_loadAccounts()
    ↓
Get valid Access Token from AuthProvider
    ├─ Token invalid
    │   ↓
    │  Logout and return to login screen
    │
    └─ Token valid
        ↓
       AccountsProvider.fetchAccounts()
        ↓
       Call AccountsService.getAccounts()
        ↓
       Send GET /api/v1/accounts
        ├─ Success (200)
        │   ↓
        │  Parse account data
        │   ↓
        │  Group by classification (asset/liability)
        │   ↓
        │  Update UI
        │
        ├─ Unauthorized (401)
        │   ↓
        │  Clear local data
        │   ↓
        │  Return to login screen
        │
        └─ Other errors
            ↓
           Show error message
```

#### 2. Account Classification Logic (accounts_provider.dart)

```dart
// Asset accounts: classification == 'asset'
List<Account> get assetAccounts =>
    accounts.where((a) => a.isAsset).toList();

// Liability accounts: classification == 'liability'
List<Account> get liabilityAccounts =>
    accounts.where((a) => a.isLiability).toList();

// Uncategorized accounts
List<Account> get uncategorizedAccounts =>
    accounts.where((a) => !a.isAsset && !a.isLiability).toList();
```

### UI State Management

The app uses Provider for state management, with two main providers:

#### AuthProvider (auth_provider.dart)
Manages authentication-related state:
- `isAuthenticated`: Whether user is logged in
- `isLoading`: Whether loading is in progress
- `user`: Current user information
- `errorMessage`: Error message
- `mfaRequired`: Whether MFA verification is required

#### AccountsProvider (accounts_provider.dart)
Manages account data state:
- `accounts`: All accounts list
- `isLoading`: Whether loading is in progress
- `errorMessage`: Error message
- `assetAccounts`: Asset accounts list
- `liabilityAccounts`: Liability accounts list

## API Endpoints

The app interacts with the backend through the following API endpoints:

### Authentication
- `POST /api/v1/auth/login` - User login
- `POST /api/v1/auth/signup` - User registration
- `POST /api/v1/auth/refresh` - Refresh token

### Accounts
- `GET /api/v1/accounts` - Get account list (supports pagination)

### Health Check
- `GET /sessions/new` - Verify backend service availability

## Data Models

### Account Model
```dart
class Account {
  final String id;              // Account ID (UUID)
  final String name;            // Account name
  final String balance;         // Balance (string format)
  final String currency;        // Currency type (e.g., USD, TWD)
  final String? classification; // Classification (asset/liability)
  final String accountType;     // Account type (depository, credit_card, etc.)
}
```

### AuthTokens Model
```dart
class AuthTokens {
  final String accessToken;     // Access token
  final String refreshToken;    // Refresh token
  final int expiresIn;          // Expiration time (seconds)
  final DateTime expiresAt;     // Expiration timestamp
}
```

### User Model
```dart
class User {
  final String id;              // User ID (UUID)
  final String email;           // Email
  final String firstName;       // First name
  final String lastName;        // Last name
}
```

## Security Mechanisms

### 1. Secure Token Storage
- Uses `flutter_secure_storage` for encrypted token storage
- Tokens are never saved in plain text in regular storage
- Sensitive data is automatically cleared when app is uninstalled

### 2. Token Expiration Handling
- Access Token is automatically refreshed using Refresh Token after expiration
- Requires re-login when Refresh Token is invalid
- All API requests check token validity

### 3. Device Tracking
- Records device information on each login (device ID, model, OS)
- Backend can manage user sessions based on device information

### 4. HTTPS Support
- Production environment enforces HTTPS
- Development environment supports HTTP (local testing only)

## Theme & UI

### Material Design 3
The app follows Material Design 3 specifications:
- Dynamic color scheme (based on seed color #6366F1)
- Rounded cards (12px border radius)
- Responsive layout
- Dark mode support (follows system)

### Responsive Design
- Pull-to-refresh support
- Loading state indicators
- Error state display
- Empty state prompts

## Development & Debugging

### Environment Configuration

#### Android Emulator
```dart
// lib/services/api_config.dart
static String _baseUrl = 'http://10.0.2.2:3000';
```

#### iOS Simulator
```dart
static String _baseUrl = 'http://localhost:3000';
```

#### Physical Device
```dart
static String _baseUrl = 'http://YOUR_COMPUTER_IP:3000';
// Or use production URL
static String _baseUrl = 'https://your-domain.com';
```

### Common Commands

```bash
# Install dependencies
flutter pub get

# Run app
flutter run

# Build APK
flutter build apk --release

# Build App Bundle
flutter build appbundle --release

# Build iOS
flutter build ios --release

# Code analysis
flutter analyze

# Run tests
flutter test
```

### Debugging Tips

1. **View Network Requests**:
   - Android Studio: Use Network Profiler
   - Or add `print()` statements in code

2. **View Stored Data**:
   ```dart
   // Add at debugging point
   final prefs = await SharedPreferences.getInstance();
   print('Backend URL: ${prefs.getString('backend_url')}');
   ```

3. **Clear Local Data**:
   ```bash
   # Android
   adb shell pm clear com.example.sure_mobile

   # iOS Simulator
   # Long press app icon -> Delete app -> Reinstall
   ```

## CI/CD

The project is configured with GitHub Actions automated builds:

### Trigger Conditions
- Push to `main` branch
- Pull Request to `main` branch
- Only triggers when Flutter-related files change

### Build Process
1. Code analysis (`flutter analyze`)
2. Run tests (`flutter test`)
3. Android Release build (APK + AAB)
4. iOS Release build (unsigned)
5. Upload build artifacts

### Download Build Artifacts
Available on GitHub Actions page:
- `app-release-apk`: Android APK file
- `app-release-aab`: Android App Bundle (for Google Play)
- `ios-build-unsigned`: iOS app bundle (requires signing for distribution)

## Future Extensions

### Planned Features
- **Transaction History**: View and manage transaction history
- **Account Sync**: Support automatic bank account synchronization
- **Budget Management**: Set and track budgets
- **Investment Tracking**: View investment returns
- **AI Assistant**: Financial advice and analysis
- **Push Notifications**: Transaction alerts and account change notifications
- **Biometric Authentication**: Fingerprint/Face ID quick login
- **Multi-language Support**: Chinese/English interface switching
- **Chart Analysis**: Financial data visualization

### Technical Improvements
- Offline mode support
- Data caching optimization
- More robust error handling
- Unit tests and integration tests
- Performance optimization
