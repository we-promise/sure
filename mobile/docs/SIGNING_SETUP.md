# Android Signing Setup Guide

## GitHub Secrets Configuration

To enable CI/CD automatic signing of APK/AAB files, you need to configure the following Secrets in your GitHub repository:

### Step 1: Get Keystore Base64 Encoding

The base64 encoding of your keystore has been generated in the `keystore-base64.txt` file in the project root directory.

View the content:
```bash
cat keystore-base64.txt
```

### Step 2: Add Secrets on GitHub

Navigate to your GitHub repository:
1. Click on **Settings**
2. In the left menu, click on **Secrets and variables** > **Actions**
3. Click the **New repository secret** button
4. Add the following four secrets:

| Secret Name | Value |
|------------|-----|
| `KEYSTORE_BASE64` | The base64 string copied from `keystore-base64.txt` |
| `KEY_STORE_PASSWORD` | Your keystore password |
| `KEY_PASSWORD` | Your key password |
| `KEY_ALIAS` | Your key alias |

### Step 3: Verify Setup

After completing the setup, push code to the main branch or create a Pull Request. The CI/CD will automatically:
1. Run tests
2. Build signed APK
3. Build signed AAB
4. Upload build artifacts to GitHub Actions artifacts

## Local Build

Local build is already configured, with signing information in the `android/key.properties` file.

Build signed versions locally:
```bash
flutter build apk --release
flutter build appbundle --release
```

## Security Notes

- ✅ `key.properties` and keystore files have been added to `.gitignore`
- ✅ These files will not be committed to the Git repository
- ✅ CI/CD uses GitHub Secrets to securely store signing information
- ⚠️ Please keep the `keystore-base64.txt` file safe; you can delete it after setting up GitHub Secrets

## Keystore Information

- **File Location**: `android/app/upload-keystore.jks`
- **Validity**: 10,000 days

⚠️ **Important Notice**:
- Please keep your keystore password, key password, and alias safe
- This information is only stored locally in the `android/key.properties` file (added to .gitignore)
- GitHub Secrets also need to be configured with this information
- Be sure to back up your keystore file - losing it will prevent you from updating published applications!
