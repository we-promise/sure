# iOS TestFlight GitHub Action

This repository now includes `.github/workflows/ios-testflight.yml`, which builds a **signed** iOS IPA and uploads it to TestFlight.

## What must be in the repo

- The workflow file itself: `.github/workflows/ios-testflight.yml`
- Existing app signing identifiers in Xcode:
  - Bundle ID `am.sure.mobile` (or your custom value in the workflow)
- Flutter assets and source already in `mobile/`

## Trigger paths

- Manual dispatch from the workflow UI.
- Tag push matching `ios-v*`.
- Called from `.github/workflows/mobile-release.yml` after the shared build job, so tagging `mobile-v*` now creates the GitHub release and uploads to TestFlight in one pipeline.

## Required GitHub Secrets

Set these in **Settings → Secrets and variables → Actions**:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_BASE64`
  - Base64 version of the `.p8` private key content
- `IOS_TEAM_ID`
- `IOS_KEYCHAIN_PASSWORD`
- `IOS_DISTRIBUTION_P12_BASE64`
- `IOS_DISTRIBUTION_P12_PASSWORD`
- `IOS_DISTRIBUTION_CERT_NAME`
  - Usually `iPhone Distribution`
- `IOS_PROVISIONING_PROFILE_NAME`
- `IOS_PROVISIONING_PROFILE_BASE64`

> Do **not** commit private keys, `.p12`, `.mobileprovision` or `.p8` files to the repository.

## Triggering

- Run manually: **Actions → iOS TestFlight → Run workflow**
- Push a tag that matches `ios-v*` (for example `ios-v1.2.3`)

## Recommended App Store Connect setup

- Use an API Key with App Manager or Developer role
- Create/download an iOS Distribution certificate (`.p12`), convert to base64 for `IOS_DISTRIBUTION_P12_BASE64`
- Create and distribute an **App Store** provisioning profile for `am.sure.mobile`
- Base64-encode the `.mobileprovision` file for `IOS_PROVISIONING_PROFILE_BASE64`

## Output

- IPA artifact: `ios-ipa-testflight`
- Uploaded IPA to TestFlight on successful upload step

