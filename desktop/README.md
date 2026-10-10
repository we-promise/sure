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

## Reports and downloads

Files your Sure server sends as downloads (CSV exports, statements, transaction
attachments, the import sample CSV) are saved in the macOS Downloads folder,
even when the app could display them. When a download finishes or fails, Sure
shows its usual message in the window, or in the main window when the download
came from a window that closed itself. A native notification is also sent when
that window is not in front, and replaces the message when the window is hidden
or the server is too old to provide it (allow Sure notifications in System
Settings to see them). The notification uses the message's text in Sure's
language, and is in English only with a server too old to provide the message.
Repeated downloads get a numbered filename.

Print Report opens a separate Sure window using the current signed-in session,
then the native print dialog once the report has loaded. Print it, or choose
PDF → Save as PDF. Close the report window to return to the app.

Other links that open a new window follow the same rule: pages of your Sure
server open in a separate Sure window with your session, and other websites
open in your default browser. Only the main window has the desktop
integrations: notifications and SSO in your browser. Downloads are only
accepted from pages of your saved servers.

To verify changes to this flow, run `npm run build` in `desktop`, then
`cargo test --locked` in `desktop/src-tauri`. In the desktop app, export a
report CSV twice and check both files in Downloads. Download a statement PDF
and a transaction attachment, check that the app page stays in place, and open
Print Report to save a PDF. Open a CSV statement with its view link (the eye
icon on an account's statements): the file is saved in Downloads, no empty Sure
window stays open, and the message appears in the main window.
Open an external link (for example the Discord help icon) and check that it
opens in your browser. Repeat against a server mounted under a URL prefix, if
applicable.

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
   VERSION="<release-version>"
   xcrun notarytool submit "src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_${VERSION}_universal.dmg" \
     --apple-id "<APPLE_ID>" --team-id "<TEAMID>" --password "<APP_SPECIFIC_PW>" --wait
   xcrun stapler staple "src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_${VERSION}_universal.dmg"
   ```
These steps require an Apple Developer account and are intentionally left as a
documented follow-up.

## Not built yet (see spec §9)
- Balance-with-sparkline glance widget (Tauri floating panel and/or a WidgetKit
  Notification Center widget with App Group data sharing), fed by an
  auto-provisioned read-only API key polling `/api/v1`. Deferred by design.
