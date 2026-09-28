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
