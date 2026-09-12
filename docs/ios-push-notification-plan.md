# iOS push notification implementation plan

Prepared September 11, 2026. This is a source review and proposed implementation sequence, not confirmation that production push delivery is configured or working.

Reviewed Rails checkout `38be19fa7d385ab9b344bbab367c6f63a4b6c24a` and [swift-sure](https://github.com/sure-admin/swift-sure/tree/1d51fc447b7e0225f559cac9119ba67295a5ca6f) at `1d51fc447b7e0225f559cac9119ba67295a5ca6f`.

## Existing foundation

| Area | Already implemented |
| --- | --- |
| Rails registration | `PushSubscription`, authenticated `POST /api/v1/push_subscriptions` and owner-scoped `DELETE /api/v1/push_subscriptions/:id`; OAuth and API keys supported, writes require write scope. |
| Rails delivery | `Apns::Client` uses the existing Apnotic dependency, token authentication, sandbox/production routing, generic localized alert copy, and an insight collapse ID. |
| Trigger | `GenerateInsightsJob` enqueues notifications for new and resurfaced insights; daily generation runs at 06:00 UTC, with manual refresh also able to trigger generation. |
| Eligibility | Enqueue requires configured APNs credentials, user preview opt-in, and a subscription registered within 90 days. Delivery checks family membership. |
| Swift | Permission prompt, APNs delegate callbacks, token formatting, registration API client, persisted subscription state, and logout/server-change cleanup with deferred retries. |
| Tests/docs | Rails API and APNs tests, OpenAPI documentation, and Swift notification lifecycle/API tests already exist. |

The initial release should finish and validate this insight notification path. Keep additional events, such as rule matches, completed assistant replies, or provider reconnect requests, as a later extension with explicit product scope.

## 1. Establish the deployment and notification contract

**Owners: backend, iOS, operations.**

- Start with direct APNs delivery from the Sure-operated Rails deployment to the official iOS app, bundle ID `am.sure.insights`.
- Define the initial policy as opt-in, high-priority insights only, matching the current Swift label “Notify urgent insights.” Today generation enqueues every new/resurfaced insight regardless of priority. Preview access and notification consent are separate controls.
- Define whether the preference applies to a device or all of a user's devices; preserve the existing per-device behavior for the first release. Add an explicit server-side enabled state if subscriptions will remain after opt-out.
- Preserve the existing payload fields `insight_id` and `destination: "insights"`. Keep balances, transaction descriptions, and insight prose out of lock-screen text. Resolve details through the authenticated API.
- Specify the behavior when preview access, write scope, server support, or APNs configuration is unavailable. The app should distinguish permission granted, registration pending, enabled, and unavailable.
- Document that the current trigger is scheduled/manual insight generation. If urgent means prompt detection after financial changes, add a separate, debounced post-sync generation requirement; the current nightly schedule does not provide that guarantee.

**Deployment restriction (confirmed):** all native push functionality is hosted-only. The Rails configuration names this mode `managed`; use `Rails.application.config.app_mode.managed?`. Self-hosted deployments must not expose the push section or support subscription endpoints or delivery, even if APNs credentials or old subscription rows exist. Enforce this at API/admin entry points, enqueueing, and worker/transport execution. No self-hosted app configuration or push relay is in scope. Swift must treat the API's `feature_disabled` response as unavailable and avoid presenting push as enabled for that connection.

**Exit criterion:** agreed event policy, deployment support matrix, compatible payload and API behavior, including hosted-only rejection.

## 2. Verify Apple provisioning and server configuration

**Owner: operations, with iOS support.**

- Enable Push Notifications for the official App ID and verify the signed development and distribution artifacts carry the correct entitlement. The source entitlement says `development`; inspect the actual exported TestFlight artifact before assuming its environment.
- Provision an APNs token-authentication key for the appropriate team, topic, and environments. Configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID=am.sure.insights`, and `APNS_PRIVATE_KEY_BASE64` in the server/worker secret store. Base64 is encoding, not encryption; the private key stays server-side.
- Verify workers consume the existing `scheduled` queue and can reach APNs over HTTP/2/TLS. Confirm the insight schedule is loaded.
- Add Rails hosting documentation and example variable names without secret values. Validate malformed/missing configuration and expose a safe operational health result and explicit delivery kill switch.
- Use the System Health test-push action described below for smoke notifications to the logged-in super-admin's enabled devices in sandbox and production. Validate a real TestFlight device as well as development; inspect both APNs acceptance and device presentation.

Apple references: [app registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [APNs connections](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns), and [request format](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).

**Exit criterion:** verified sandbox and TestFlight delivery with documented credential ownership and rotation.

## 3. Repair registration freshness and account lifecycle

**Owners: iOS and backend.**

- Fix the confirmed freshness mismatch: Swift skips POST when the token/server/environment is unchanged, but Rails stops sending after `last_registered_at` is 90 days old. Persist the last successful server refresh and renew on authenticated foreground/launch at a defined interval, for example daily. Serialize concurrent renewals and retry transient failures without repeatedly prompting for permission.
- Keep requesting the current token from APNs on launch. Handle token rotation, a server-deleted subscription, and returning after a long absence. Refresh notification authorization when returning from Settings.
- Bind persisted subscription and cleanup state to authenticated account identity as well as server URL. Current Swift records are server-bound; test switching users on the same server, especially when logout cleanup failed.
- Define safe ownership transfer or recovery for an existing token. Rails currently rejects a token belonging to another user. Do not remove owner checks or silently transfer a token merely to resolve that conflict. An installation-bound credential/revocation mechanism can support recovery and removal without retaining old login credentials.
- Make opt-out/logout disable delivery durably when online. Define offline behavior honestly: cleanup cannot reach the server while disconnected. Retain pending revocation state, associate subscriptions with a revocable installation/session where appropriate, and ensure old-account alerts cannot open data under the next account.
- Review token identity constraints using environment and configured topic, and replace the current 64–200-character assumption with variable-length token handling plus a defensible request-size limit. Apple explicitly says [not to hard-code token size](https://developer.apple.com/documentation/UIKit/UIApplicationDelegate/application%28_%3AdidRegisterForRemoteNotificationsWithDeviceToken%3A%29?language=objc).

**Exit criterion:** an unchanged token stays active beyond 90 days; rotation, reinstall, opt-out, and same-host/cross-host account transitions recover without cross-user delivery.

## 4. Make delivery eligibility and retries reliable

**Owner: backend.**

- Recheck eligibility immediately before sending: active user, family membership, preview access, current subscription/consent, high priority, and a still-relevant insight. Existing execution only rechecks family membership. Reuse the insight API's authorization policy and audit any account-visibility restrictions before adding account-specific events.
- Add durable per-event/per-subscription delivery records and record the event alongside the insight change, then dispatch after commit with reconciliation for missed enqueueing. Today persistence and enqueueing are separate, so a failure between them can lose an alert.
- Identify an insight occurrence/revision explicitly: deduplicating forever on insight ID would suppress legitimate resurfacing; `generated_at` is refreshed on unchanged insights and is not a reliable event version. Use a unique database key for occurrence plus subscription and record attempts, APNs acceptance, failure category, and timestamps.
- Keep the existing `NotificationDelivery` model for rule-email deduplication; its required rule/transaction associations do not fit insight push delivery. Add a focused push record instead of overloading it.
- Classify responses: retry network failures, throttling, and transient server errors with bounded backoff; surface configuration/authentication/payload failures without repeatedly retrying unchanged invalid requests. Treat `BadDeviceToken` as a possible environment mismatch as well as invalid registration.
- Process `410 Unregistered` conditionally using APNs' invalidation timestamp and the token/registration version sent, so a delayed response cannot remove a freshly registered subscription. See [Apple response semantics](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
- Set an explicit expiration policy and collapse behavior for stale/superseded insights. Recognize that a collapse ID is not exactly-once delivery; an ambiguous timeout can still produce duplicates. Measure APNs acceptance separately from device delivery or user opens.
- Use sanitized `DebugLogEntry.capture` diagnostics and metrics for queued, accepted, rejected, retried, expired, and invalidated notifications. Preserve token/secret filtering. Consider bounded connection reuse after correctness is established; the current client opens a connection per send.

**Exit criterion:** retries and repeated generation do not cause routine duplicate alerts; missed jobs can be recovered; revoked access prevents queued sends; APNs faults are diagnosable.

## 5. Finish the Swift notification experience

**Owner: iOS.**

- Implement consumption of `pendingInsightID`: the delegate currently persists it, but no app navigation code reads it. Route to Overview/Insights, refresh through the authenticated API, and reveal the referenced insight.
- Handle foreground, background, and cold-start taps; defer navigation while sign-in completes. If the insight is unavailable, expired, or unauthorized, show a safe fallback. Bind pending navigation to the originating connection/account and clear it on logout or connection changes.
- Display registration failures and pending/retry state. Currently `registrationError` is persisted but no UI reads it, and enabling can report success even when the server registration failed.
- Implement permission-denied guidance and Settings return handling. Preserve generic lock-screen copy and decide foreground banner/sound behavior explicitly.

**Exit criterion:** a tap reaches the appropriate authorized content from every app state, and the notification setting reflects actual registration state.

## 6. Add a System Health test-push button

**Owner: backend, with iOS support for the test payload. User-requested scope; hosted (`managed`) mode only.**

- In hosted mode, add a **Push notifications** section within **Background jobs** at `/admin/system_health?tab=background_jobs#push-notifications` with a **Send test push notification** button. Match the AI tab's description/action layout and existing `DS::Button` outline, small-size styling; keep the existing two tabs and use localized strings, functional design tokens, and the existing icon API. No design-system stylesheet changes are needed.
- The button sends only to the super-admin account currently logged into the web app. Resolve the recipient exclusively from `Current.user`; fan out to that user's eligible iOS subscriptions, never to other super-admins or family members. Do not accept a recipient user ID or arbitrary device token from the request.
- Render a genuinely disabled button when that super-admin has no enabled, current push subscriptions. Show explanatory text such as “Enable push notifications in the Sure iOS app for this account to send a test.” Use a shared server-side eligibility predicate incorporating subscription freshness, revocation, and any explicit consent state introduced by this plan. Preview opt-in alone does not mean push is enabled. The server can report only the latest registered authorization state; synchronize permission changes through the Swift lifecycle work.
- Hide the entire push section in self-hosted mode and reject direct test-push POSTs. Also disable sending when APNs is unconfigured or the delivery kill switch is active, with a distinct explanation. Recheck all conditions server-side on submission; a disabled button alone does not enforce eligibility.
- Add a CSRF-protected `POST /admin/system_health/send_test_push` action to `Admin::SystemHealthController`, retaining `Admin::BaseController`'s super-admin authorization. Keep the controller thin and enqueue a dedicated test delivery job through Active Job/Sidekiq on the existing `scheduled` queue. Follow the asynchronous `verify_worker_ai` action's redirect/queued-feedback pattern; the AI tab's GET-based “Run checks again” control is a visual reference, not the HTTP method for sending a notification.
- Pass the initiating user's ID and eligible subscription IDs to the delivery workflow, then recheck active super-admin status, subscription ownership, consent/freshness, and delivery availability when the job runs. A logout-driven revocation, role change, or opt-out after clicking must prevent the queued send.
- Send a generic localized diagnostic alert, for example “Sure test notification” / “Push notifications are working for your account.” Reuse the APNs transport, environment selection, retry handling, and sanitized delivery tracking. Give each test request its own identifier, with per-subscription retry deduplication and brief protection against accidental repeated clicks.
- The diagnostic must not require, generate, or mutate a financial insight. Extend the transport's current required `insight_id` interface with an explicit test payload; tapping it should safely open the app's Overview. Insight priority and insight preview gates apply to financial alerts, not this explicit super-admin diagnostic; registered push consent remains required.
- Title the section **Push notifications** and show **Latest test requested at …** when a test exists. Immediately show **Test notification queued**, then expose the current user's latest test result with per-device APNs acceptance/failure or skipped status and a timestamp. Do not label queueing or APNs acceptance as confirmed device delivery. Render sanitized errors without tokens or credentials.

**Acceptance coverage:** enabled and disabled button states; missing configuration and kill switch; unauthenticated/non-super-admin rejection; no eligible device; current-user-only fan-out even when other super-admins/family members have subscriptions; forged recipient parameters; enqueueing without synchronous APNs calls; revocation/role/ownership changes before execution; partial device failures; safe payload/tap behavior; and accessible localized status messages. Add focused Minitest controller/job tests and a system test for the critical button flow.

**Exit criterion:** an opted-in super-admin can queue a test from System Health and inspect its outcome; an account without push enabled cannot send through either the UI or direct POST.

## 7. Validate and release in stages

**Owners: backend and iOS, with operations for acceptance.**

- Backend coverage: registration renewal/concurrency, owner isolation, read-only scope rejection, variable-length tokens, stale subscriptions, revoked consent/preview, deactivated users, family changes, stale insight events, duplicate jobs, transient/permanent APNs responses, and invalidation/renewal races.
- Swift coverage: unchanged-token renewal with an injected clock, token rotation, permission changes, failed registration recovery, same-host account changes after failed cleanup, host isolation, and notification navigation across launch/authentication states.
- Contract coverage: retain existing POST 201 and DELETE 204 behavior unless a coordinated version change is necessary. Update Minitest behavioral tests with the repository's `X-Api-Key` pattern, documentation-only rswag specs/shared schemas, and regenerate OpenAPI. Validate runtime OAuth interoperability through the Swift/auth integration coverage.
- Before implementation PRs, run all required Rails checks: full Minitest, applicable system tests, Ruby and ERB lint, Biome, and Brakeman. Run the Swift repository's iOS/macOS/watch test destinations and signed device acceptance tests.
- Roll out to internal preview users first, then a small TestFlight cohort. Verify opt-out and kill-switch behavior before expanding. Monitor queue latency, acceptance/error rates, registration freshness, and duplicate reports.
- Expand event types only after this path is stable. Introduce a versioned typed payload and shared delivery policy when the second event is selected; each event needs recipient rules, preference controls, authorized navigation, and its own deduplication semantics.

**Suggested work packages:** (1) deployment contract and runbook; (2) registration/lifecycle fixes across both repositories; (3) Rails delivery policy and durable dispatch; (4) Swift routing/status UI; (5) System Health test-push section/action using the shared eligibility and delivery infrastructure; (6) end-to-end acceptance and staged rollout. After the contract is agreed, registration, delivery, and UI implementation can progress independently against it.

## Implementation progress

The first Rails milestone adds hosted-only API/admin/worker/transport guards, the System Health test-push action, per-device Sidekiq diagnostics, high-priority/send-time insight eligibility checks, shared APNs error handling, registration-safe invalidation, bounded token input, and a [hosting runbook](hosting/push-notifications.md).

Diagnostic results use the existing shared Rails cache pattern with 24-hour retention; they are not the durable insight event/delivery ledger described in step 4. The Swift lifecycle/navigation changes, durable insight dispatch, Apple provisioning, and live device acceptance remain follow-up work. The test payload safely omits an insight ID; explicit Overview navigation requires the planned Swift update.

The original planning review did not inspect production credentials or signed app artifacts or send a live push. Implementation verification is reported separately.
