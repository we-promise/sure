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
Everything happens in GitHub — no local git commands:

> **Actions → Desktop Release → Run workflow → enter a version (e.g. `0.1.0`)**

`.github/workflows/desktop-release.yml` then syncs the version into
`desktop/package.json` + `desktop/src-tauri/tauri.conf.json`, builds the
universal `.dmg` on a macOS runner, and creates the `desktop-v0.1.0` tag + a
GitHub Release with the `.dmg` attached. It refuses to reuse an existing
version, and marks pre-release versions (e.g. `0.1.0-beta.1`) as prereleases.

Prefer git tags? Pushing `desktop-v0.1.0` triggers the same build (version
derived from the tag).

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

## Code signing & notarization (required for distribution — NOT wired up)
No Apple Developer credentials are needed to build/run locally. To ship a
distributable, signed, notarized `.dmg`, add:
1. An **Apple Developer ID Application** certificate in your login keychain.
2. Tauri signing config in `src-tauri/tauri.conf.json` under `bundle.macOS`:
   `"signingIdentity": "Developer ID Application: <NAME> (<TEAMID>)"`,
   `"hardenedRuntime": true`, and an `entitlements` plist if needed.
3. Notarization after build:
   ```bash
   xcrun notarytool submit Sure_0.1.0_aarch64.dmg \
     --apple-id "<APPLE_ID>" --team-id "<TEAMID>" --password "<APP_SPECIFIC_PW>" --wait
   xcrun stapler staple Sure_0.1.0_aarch64.dmg
   ```
These steps require an Apple Developer account and are intentionally left as a
documented follow-up.

## Not built yet (see spec §9)
- Balance-with-sparkline glance widget (Tauri floating panel and/or a WidgetKit
  Notification Center widget with App Group data sharing), fed by an
  auto-provisioned read-only API key polling `/api/v1`. Deferred by design.
