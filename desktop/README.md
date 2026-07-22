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
npm run tauri build
# Output: src-tauri/target/release/bundle/dmg/Sure_0.1.0_aarch64.dmg
#         src-tauri/target/release/bundle/macos/Sure.app
```

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
