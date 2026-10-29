# Hosted iOS push notifications

Native push notifications are supported only in hosted mode, which Rails calls
`managed`. `SELF_HOSTED=true` or `SELF_HOSTING_ENABLED=true` disables registration,
unregistration, diagnostic controls, and APNs delivery. Existing tokens and
configured Apple credentials do not override that restriction.

## Server and worker configuration

Set the following in the deployment secret store for both Rails web processes
and Sidekiq workers:

| Variable | Purpose |
| --- | --- |
| `APNS_KEY_ID` | Apple APNs signing key ID |
| `APNS_TEAM_ID` | Apple Developer team owning the app |
| `APNS_BUNDLE_ID` | Official iOS app topic: `am.sure.insights` |
| `APNS_PRIVATE_KEY_BASE64` | Base64-encoded APNs `.p8` private key; keep server-side |
| `APNS_ENABLED` | Set to `false` to stop push delivery after web/worker processes load the updated environment; defaults to enabled when configured |
| `REDIS_URL` | Shared Redis for Sidekiq and Rails diagnostic cache |

Base64 does not encrypt the signing key. Do not embed it in the iOS app, logs, or
repository. Configure the same shared Rails Redis cache on web and worker
processes; a process-local memory/null cache cannot coordinate these diagnostics.
Workers must consume the existing `scheduled` queue and reach the sandbox and
production APNs endpoints over HTTP/2/TLS. No additional gem or database migration
is needed for the System Health diagnostic.

Verify Push Notifications is enabled for the app's Apple App ID. Inspect the
entitlements of the signed development and TestFlight artifacts, and verify their
APNs environments. Registrations select `sandbox` or `production` per device.

## Send a diagnostic notification

1. Sign into the Sure iOS app with the same hosted account as the super-admin
   signed into the web app, and enable push notifications.
2. Open **System Health → Background jobs → Push notifications** in the web app.
3. Select **Send test push notification**. This sends only to that account's
   recently registered iOS devices; no recipient can be selected in the request.
4. Select **Refresh results** to see each device's outcome. Results remain for
   24 hours. **Accepted by APNs** confirms Apple's acceptance, not presentation
   on the device. Confirm the alert on a development device and a TestFlight build.

The button is disabled when there is no current registration, APNs is unconfigured,
delivery is disabled, or another test was requested in the last 30 seconds. A
registration currently counts as enabled until it is removed or becomes stale;
iOS permission changes must be synchronized by the app. This server-side state
cannot prove the current device permission while the device is offline.

Tests run through Sidekiq, one job per device, with generic localized text and no
financial information. They do not create an insight or require insight preview
access. Requests older than 15 minutes are skipped. Ordinary job replays reuse a
terminal diagnostic result; this short-lived cache is not an exactly-once delivery
guarantee. A lost cache entry prevents a diagnostic send rather than inventing a
recipient from stale arguments.

## Outcomes and troubleshooting

- **Queued / retrying:** check worker availability and the `scheduled` queue.
- **Skipped:** eligibility, ownership, role, mode, configuration, or freshness
  changed after the test was requested.
- **Rejected by APNs:** check the `push_notifications` category in Debug logs.
  Verify bundle ID, key/team, and device environment; `BadDeviceToken` may indicate
  an environment mismatch. Raw tokens and APNs response bodies are not recorded.
- **Device registration is no longer valid:** the worker received APNs `410`.
  Removal is conditional on the registration not being renewed in the meantime.
- **Could not enqueue:** check Sidekiq/Redis availability and submit again after
  the cooldown. No device send occurred for that result.
- **Expired without a final result:** the request outlived the send window without
  a completed outcome; check worker connectivity and request a fresh test.

Only temporary connection errors, HTTP 429, and HTTP 5xx responses receive the
explicit bounded retry policy. Configuration and other APNs rejections are surfaced
for operator correction. Each send has connection and response timeouts, and test
notifications expire at APNs after five minutes.

Normal insight notifications require an active user, current registration, preview
opt-in, and a high-priority active insight at execution time. The diagnostic checks
active super-admin status and device ownership again in the worker. Disabling
push delivery stops both paths, while registration remains available in hosted mode
so a temporary delivery outage does not prevent token renewal.

## Remaining release work

The Swift app still needs periodic registration renewal (Rails currently excludes
registrations older than 90 days), account-bound lifecycle recovery, visible
registration error state, and navigation for insight/test notification taps.
Durable insight delivery tracking and recovery across enqueue failures are a
separate implementation step. Provisioning and live sandbox/TestFlight acceptance
must be completed before declaring push delivery ready for rollout.

# Browser and installed PWA notifications

Browser Web Push is a separate preview feature available in both managed and
self-hosted installations. It does not require an Apple Developer account or
change the hosted-only native APNs restrictions above. It reuses existing
insights; it does not introduce additional financial analysis or thresholds.

## Configure Web Push

Run the included database migration and set these variables in the secret store
for both Rails and Sidekiq:

| Variable | Purpose |
| --- | --- |
| `WEB_PUSH_VAPID_PUBLIC_KEY` | URL-safe Base64 public VAPID key; shared with browsers |
| `WEB_PUSH_VAPID_PRIVATE_KEY` | Matching URL-safe Base64 private VAPID key; server-side only |
| `WEB_PUSH_VAPID_SUBJECT` | Operator contact URI, such as `mailto:operator@example.com` or an HTTPS URL |

Generate the key pair once with the maintained `web-push` gem, for example from
your deployment's Rails console using `WebPush.generate_key`. Store its
`public_key` and `private_key` in your secret store. Keep the same pair on web and
worker processes and across deploys. Never commit the private key. Rotating the
pair requires browsers to disable and enable notifications again.

The application must be served over HTTPS, and workers must consume `scheduled`.
Allow outbound TLS on port 443 to the browser push services: `fcm.googleapis.com`,
`updates.push.services.mozilla.com`, subdomains of `push.apple.com`, and subdomains
of `notify.windows.com`. Registration accepts only those HTTPS destinations,
without user info, fragments, or nonstandard ports. Provider redirects are rejected.
The `web-push` gem handles encryption and VAPID signing; Sure does not implement
its own notification cryptography. Endpoints and subscription keys are filtered
from request logs and encrypted at rest when Rails encryption is configured.

## Enable and verify a device

1. Sign in, turn on **Settings → Preferences → Enable preview features**, then
   select **Enable this device** in **Browser notifications**. Permission is
   requested only from that button. Each browser profile or installed app must
   opt in separately.
2. On iPhone and iPad, use Safari's **Share → Add to Home Screen**, open the
   installed app, sign in there, and enable notifications there. Web Push requires
   iOS/iPadOS 16.4 or later. Other browser and operating system support varies.
3. Select **Test this device**. Only the registration bound to this browser's
   current Sure session can be tested. The control is limited to once per
   30 seconds per registration.
4. Wait for the displayed result, then check the actual device. **Queued** means
   the background job was queued. **Accepted by the push service** means the
   provider accepted it; it does not prove that the operating system displayed
   it. Browser permission, Focus/Do Not Disturb, and OS settings affect display.

Notifications are bound to the authenticated Sure session. Signing out, revoking
that session, deactivating the account, or **30 days of session inactivity** stops
delivery. Open Sure regularly to refresh the existing session; after expiry,
sign in and enable this device again. The normal session timeout is unchanged.
Disabling preview features also stops sends. Use **Disable this device** before
changing accounts on shared devices. When a browser is registered under another
session or user, the existing subscription's two secret keys prove continuity;
Sure replaces the old row so queued jobs cannot reach the new account through it.

## Alerts, privacy, and delivery behavior

An enabled device receives new or materially resurfaced, high-priority active
insights visible to the family. Enabling a device does not send a backlog.
**Budget warnings** is an independent per-user preference, off by default. It
adds the existing medium- and high-priority `budget_at_risk` insights for near-limit
and over-budget conditions on that user's enabled browser devices. Turning it
off suppresses both priorities. `budget_on_track` is never pushed. Existing
financial generators and category thresholds are unchanged.

Lock-screen payloads contain the product name and generic localized text, with
no balances, categories, accounts, or insight prose. They use the family's
locale and link to the same-origin `/insights#insight_<id>` page. The service worker
displays a visible notification, including for malformed payloads, and caches only
the existing offline assets; it does not cache financial pages.

A durable delivery ledger records each eligible subscription together with its
material insight version in the same database transaction. Recipients are fixed
at that event: later device registration or budget opt-in does not add a backlog.
Routine generator refreshes do not create a new version. Send-time checks repeat
session, user, preview, budget preference, family, active insight, version, and
shared-account visibility checks. Retries and ordinary duplicate jobs reuse the
same ledger entry. HTTP 404/410 removes an invalid subscription. Connection
failures, HTTP 429, and HTTP 5xx receive up to five attempts with bounded backoff;
other rejections are terminal. Each send has connection and read timeouts and a
five-minute provider TTL.

The existing insight generation pass also recovers enqueue failures or pending
claims abandoned for more than 15 minutes that are still eligible. Records that
are no longer eligible become skipped. It does not replay terminal results
or turn old insights into a backlog. Recovery runs when generation next runs;
there is no additional scheduler. A provider acceptance followed by a process
crash before the database update can still result in a duplicate send. Stable
notification tags collapse ordinary duplicate presentations where the browser
supports them; this is not an exactly-once transport guarantee.
