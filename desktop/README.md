# Sure Desktop (macOS)

Native macOS shell (Tauri 2 + WKWebView) that renders the full Sure web app and
wraps it in real Mac chrome. It always talks to a Sure server you already run
(self-hosted or managed) — same trust model as a browser.

## Requirements
- Rust (stable), Node 18+, Xcode command line tools, macOS 12+.

## Run in development
```bash
cd desktop
npm install
npm run build      # builds the injected bridge.js + onboarding assets
npm run tauri dev
```
On first launch, enter your Sure server URL (e.g. `http://localhost:3000` when
running `bin/dev`). The app health-checks `{server}/up`, then loads the real
`/sessions/new` where you sign in with password or SSO (MFA supported).

## Build a release .dmg (unsigned)
```bash
cd desktop
# Single-arch (host only):
npm run tauri build
# Universal (Apple Silicon + Intel) — what releases ship:
rustup target add aarch64-apple-darwin x86_64-apple-darwin
npm run tauri build -- --target universal-apple-darwin
# Output: src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_<ver>_universal.dmg
```

## Publishing a release
The desktop build runs automatically as part of the normal Sure `v*` release.
The version comes from `.sure-version` and must match the release tag; it is
stamped into `desktop/package.json` and `desktop/src-tauri/tauri.conf.json`
only while building. The universal `.dmg` is attached to that same GitHub
Release—there is no separate desktop action, tag, or version.

## Installing an unsigned build (end users)
The published `.dmg` is **not code-signed**, so macOS Gatekeeper blocks the first
launch. To open it:
1. Drag Sure to Applications and try to open it; dismiss the warning.
2. **System Settings → Privacy & Security**, scroll down, click **Open Anyway**,
   and confirm. (On macOS 15 Sequoia the old right-click→Open shortcut is gone;
   this Settings path is the way.)

If macOS instead says the app is "damaged", the download was quarantined — strip
it once in Terminal:
```bash
xattr -cr /Applications/Sure.app
```
Signing + notarization (below) removes this friction entirely.

## Rust tests
```bash
cd desktop/src-tauri
cargo test
```

## Deep links
Registered scheme: `sure://{host}[:port]/{path}` → opens the app to that
server/page. Example: `open "sure://localhost:3000/accounts"`. (Works from the
bundled `.app`, not `tauri dev`.)

## Code signing & notarization
No Apple Developer credentials are needed to build/run locally. Release builds
use GitHub Actions to sign with a Developer ID Application certificate and
notarize the universal `.dmg` with Apple.

Configure these GitHub secrets before publishing a tagged release:
- `APPLE_CERTIFICATE`: base64-encoded `.p12` for the Developer ID Application certificate.
- `APPLE_CERTIFICATE_PASSWORD`: password for that `.p12`.
- `APPLE_SIGNING_IDENTITY`: certificate identity, e.g. `Developer ID Application: <NAME> (<TEAMID>)`.
- `APPLE_ID`: Apple ID email.
- `APPLE_PASSWORD`: app-specific password for that Apple ID.
- `APPLE_TEAM_ID`: Apple developer team id.

The release workflow imports the certificate into a temporary runner keychain,
builds with Tauri's hardened runtime enabled, notarizes with Apple, staples the
ticket, then uploads the signed `.dmg` as a release artifact.

## Not built yet (see spec §9)
- Balance-with-sparkline glance widget (Tauri floating panel and/or a WidgetKit
  Notification Center widget with App Group data sharing), fed by an
  auto-provisioned read-only API key polling `/api/v1`. Deferred by design.
