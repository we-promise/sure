# Sure for iOS and iPadOS

This SwiftUI client connects directly to a Sure instance with `X-Api-Key` authentication.

## Demo connection

- Server: `https://demo.sure.am`
- Sign in through the demo website using the credentials presented there.
- Create a **read/write** key under Settings → API keys, then paste it into the native app. The key is stored only in the device Keychain.

Do not commit an API key. The shared demo account is refreshed regularly, so a generated key may need to be recreated.

## AI insight notifications

The app target includes the APNs entitlement and registers device tokens only after the user enables AI insight notifications. Tokens are sent to `POST /api/v1/push_subscriptions` with their sandbox or production environment. The project source intentionally keeps `aps-environment` set to `development`; Apple distribution signing replaces it with `production` for TestFlight and App Store builds.

Server delivery additionally requires a paid Apple Developer Program membership and an APNs authentication key (`.p8` contents, key ID, and team ID). Keep those values in backend secrets; never add them to this app or repository. Development installs use APNs sandbox, while TestFlight and App Store builds use production APNs.
