# Sure for iOS and iPadOS

This SwiftUI client connects directly to a Sure instance with `X-Api-Key` authentication.

## Demo connection

- Server: `https://demo.sure.am`
- Sign in through the demo website using the credentials presented there.
- Create a **read/write** key under Settings → API keys, then paste it into the native app. The key is stored only in the device Keychain.

Do not commit an API key. The shared demo account is refreshed regularly, so a generated key may need to be recreated.

## AI insight notifications

The app target includes the APNs entitlement and registers device tokens only after the user enables AI insight notifications. Tokens are sent to `POST /api/v1/push_subscriptions` with their sandbox or production environment. The project source intentionally keeps `aps-environment` set to `development`; Apple distribution signing replaces it with `production` for TestFlight and App Store builds.

Server delivery additionally requires a paid Apple Developer Program membership and these backend secrets: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, and `APNS_PRIVATE_KEY_BASE64` (the base64-encoded `.p8` contents). Never add their values to this app or repository. Newly created or resurfaced insights enqueue one APNs delivery per recently registered device; development installs use APNs sandbox, while TestFlight and App Store builds use production APNs.
