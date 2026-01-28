# iOS Build Guide

## Issue Diagnosis: module 'flutter_secure_storage' not found

### Root Cause
This error occurs because CocoaPods dependencies have not been installed. `flutter_secure_storage` is a Flutter plugin that requires native platform support, and its iOS native code must be installed via CocoaPods.

### Solution

#### First-time Setup or After Dependency Updates
```bash
# 1. Get Flutter dependencies
flutter pub get

# 2. Navigate to iOS directory and install CocoaPods dependencies
cd ios
pod install
cd ..
```

#### Clean Build (if encountering issues)
```bash
# Clean Flutter build cache
flutter clean

# Re-fetch dependencies
flutter pub get

# Clean and reinstall Pods
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
```

## Local Building

### Method 1: Using Flutter CLI
```bash
# Debug mode
flutter build ios --debug

# Release mode (requires Apple Developer certificate)
flutter build ios --release

# Release mode (no code signing, for build testing only)
flutter build ios --release --no-codesign
```

### Method 2: Using Xcode
1. Ensure you have run `pod install`
2. Open `ios/Runner.xcworkspace` (**Note: NOT .xcodeproj**)
3. Select target device or simulator
4. Click Run button or press Cmd+R

## CI/CD Automated Builds

### GitHub Actions Workflow

The project is configured with automated iOS build process, triggered by:
- Push to `main` branch
- Pull Requests
- Manual trigger (workflow_dispatch)

#### Build Steps
1. **Environment Setup**: macOS runner + Flutter 3.32.4
2. **Dependency Installation**: `flutter pub get` + `pod install`
3. **Code Analysis**: `flutter analyze`
4. **Test Execution**: `flutter test`
5. **iOS Build**: `flutter build ios --release --no-codesign`
6. **Artifact Upload**: Built .app file saved as artifact for 30 days

#### Viewing Build Artifacts
1. Go to GitHub Actions page
2. Select the corresponding workflow run
3. Download `ios-build-unsigned` artifact

**Note**: CI-built versions are not code-signed and cannot be installed directly on physical devices.

## Code Signing and Distribution

### Configuring Code Signing
To publish to the App Store or install on physical devices, you need:

1. **Apple Developer Account** (Individual or Enterprise)
2. **Developer Certificates**
   - Development Certificate
   - Distribution Certificate
3. **Provisioning Profile**
4. **App ID** registered in Apple Developer Portal

### Configuration in Xcode
1. Open `ios/Runner.xcworkspace`
2. Select Runner target
3. Go to "Signing & Capabilities" tab
4. Set Team (requires Apple ID login)
5. Set Bundle Identifier
6. Xcode will automatically manage certificates and Provisioning Profile

### Building IPA for Distribution
```bash
# Build and archive using Xcode
flutter build ipa --release

# IPA file location
# build/ios/ipa/*.ipa
```

## System Requirements

### Development Environment
- macOS 12.0 or higher
- Xcode 14.0 or higher
- CocoaPods 1.11 or higher
- Flutter 3.32.4 (recommended)

### Minimum iOS Version
- iOS 12.0 (defined in `ios/Podfile`)

## Common Issues

### Q: Why use .xcworkspace instead of .xcodeproj?
A: When a project uses CocoaPods, Pod dependencies are organized into a separate Xcode project. The `.xcworkspace` file contains both the main project and the Pods project, and must be used to ensure all dependencies are properly loaded.

### Q: What to do after updating pubspec.yaml?
A: After adding or updating dependencies, you need to run:
```bash
flutter pub get
cd ios && pod install && cd ..
```

### Q: What if CI build fails?
A: Common causes:
1. Flutter version mismatch
2. Dependency conflicts
3. Pod installation failure
4. Code analysis or test failures

Check GitHub Actions logs for detailed error information.

### Q: How to configure code signing in CI?
A: You need to configure GitHub Secrets:
- Apple certificate (.p12 format, base64 encoded)
- Provisioning Profile
- Certificate password
- Keychain setup

This requires additional configuration steps. Currently, CI uses the `--no-codesign` option for unsigned builds.

## Related Documentation

- [Flutter iOS Deployment Documentation](https://docs.flutter.dev/deployment/ios)
- [CocoaPods Official Guide](https://guides.cocoapods.org/)
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [flutter_secure_storage Plugin Documentation](https://pub.dev/packages/flutter_secure_storage)
