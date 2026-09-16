# Account data migration implementation status

The completion target is every existing transaction-data integration on the shared
runtime, with transparent data transfer and verified preservation of financial
history. This file records implementation progress; it is not migration acceptance.
No live connection has been cut over and no migration has been executed in this
workspace. The existing edit to `db/schema.rb` belongs to the user and is preserved.

The [native input inventory](provider-native-input-audit.md) distinguishes archived
columns from executable inputs for all 23 provider families, including remaining
history, cache, topology and attachment transfer work.

## Implemented foundations, pending executable verification

- [Native disconnection from Sure](provider-native-disconnect.md) now has one
  shared review/command path. It locks the complete affected graph, rechecks
  administrator and per-account owner/full-control rights, stops native sync and
  detaches only the chosen connection's policies/links/routing references. Financial
  history, source evidence, other providers and original credentials/archives remain.
  A retained-key signed receipt supports identical completed-request replay;
  inactive balance-policy history prevents first-link fallback from silently
  promoting another source. Behavioral and browser-controller tests are authored
  but unrun. No adapter readiness changed or live disconnection occurred. Upstream
  revocation, reconnect, erasure and all-provider cutover acceptance remain gates.
- [Retained source ownership](provider-retained-owners.md) now records immutable
  mapping witnesses against live source rows, the exclusive legacy permit and
  authenticated original archives. After explicit retirement, policy selection and
  unlinking can resolve missing owners while preserving dual-link UUIDs and
  original policy tuples. Family history can retain original legacy Sync owners
  through exact connection witnesses. Additive database guards and focused tests
  are written but unrun. The explicit `MigrationRetirement` command now combines
  live source/archive parity, exact inventories, settled work, authenticated logo
  retention and callback-free compatibility-row removal with a signed durable
  receipt. Reviewed removal dispositions cover Up/Mercury/Brex/Akahu and preserve
  existing readiness gates. Their saved edit/setup/sync member URLs route through
  authenticated retained ownership; stale forms require a fresh shared submission.
  The [all-provider retirement inventory](provider-retirement-inventory.md) records
  direct-FK, deferred-request and lifecycle dispositions still needed elsewhere.
  No removal command or new tests have executed; full retirement acceptance remains
  outstanding.
- Canonical `Provider::AccountData` contracts, source-neutral `Ingestion::Record`,
  and `provider:account_data`; prior namespaces and generator commands are aliases.
  Generated packages include a pure client factory and remain inactive until their
  `native_ready?` implementation opts in. The registry discovers trusted local
  adapter declarations; request/database keys only select from that allowlist.
- [Native connection configuration](provider-native-configuration.md) now supplies
  shared browser settings and a signed, actor-bound update command. Up, Mercury, Brex and Akahu
  opt in to static token replacement; other adapters must explicitly declare a
  reviewed credential policy. Updates serialize with refresh, refuse active work
  and stale forms, preserve original migration archives, and advance native
  revisions. Settings links remain available after legacy retirement. Credential
  lock uncertainty now disconnects instead of returning an uncertain pooled
  session. Model, concurrency, lock-fault and controller tests are written but
  unrun. Local disconnection is described above; upstream revocation and
  rotating-token reauthorization remain separate lifecycle requirements.
- [Shared native account setup](provider-native-account-setup.md) now supplies
  discovery pagination, exact signed target selection, account creation with an
  explicit balance, and linking to permitted existing accounts. New links select
  their required sources only when no current source exists; secondary links keep
  existing policies. Admission checks current family/admin/account permissions,
  migration ownership, idle work and original unlinked cache disposition. Setup
  commits its link, policies and durable Sync receipt atomically; dispatch retries
  reuse that Sync. Up, Mercury, Brex and Akahu declare supported types, with
  Mercury/Brex/Akahu still disabled by native readiness. A pure, validated creation
  default hook retains Akahu subtype and Investment cash conventions; its resolved
  values join the signed selection and cannot replace explicitly entered balances.
  Model and browser tests are written but unrun.
  A [bounded retained transaction replay](retained-transaction-publication.md) publishes never-financially-bound native
  observations through a fresh batch and policy without changing original captures
  or checkpoints. Investment replay, ambiguous pending relations, provider-specific
  archived inputs, authority changes and retirement remain separate requirements.
- Additive migrations for shared connections, authorizations, external accounts,
  encrypted ingestion batches/checkpoints, migration controls/mappings, direct
  account links, source authority and financial-entry evidence.
- A resumable migration copier with explicit column dispositions for all 23 legacy
  item/account table pairs, lossless typed encrypted snapshots, integrity checks,
  preserved AccountProvider UUIDs and Plaid/SimpleFIN direct-link conflict checks.
  New account archives also bind the original link/revision and financial-account
  identity/context, including explicit unlinked state. Copy verification, identity
  planning and evidence publication reject changed bindings and older archives
  lacking that proof; later financial edits remain allowed. Tests are unrun.
  Copies stay disabled. Their `shadow` state is a comparison result, not permission
  to activate while legacy writers remain live. The internal
  [quiesced-copy path](provider-quiesced-copy.md) now retains paused ownership across
  bounded passes and failures, with explicit pre-native return to legacy operation.
  Its audit covers the declared fence and copied rows. A separate bounded retained
  copy reader now rechecks archives, targets, links and exact account inventories
  after identity publication without changing the original copy run or evidence.
  Lost identity checkpoints cannot reopen copier restart or return to legacy while
  proof remains. A [durable preparation coordinator](provider-migration-preparation.md)
  now sequences the original quiesced copy, exact linked/unlinked inventory,
  identity publication and fresh copy/identity verification sweeps. It also
  captures [logo auxiliary input for all 20 declared item scopes](provider-logo-transfer.md)
  once per connection, including empty connections,
  and installs Binance history seeds per supported source account. Both retain
  their original evidence through independent final verification. Separate
  encrypted connection/mapping receipts survive child-commit interruptions and
  block copier restart even before financial evidence exists. It stops at
  `awaiting_acceptance`; its explicit partial/unintegrated input statuses do not
  claim complete upstream coverage. Remaining auxiliary/native-checkpoint
  integration and full lifecycle drain remain unfinished. An explicit
  [shared cutover command](provider-up-cutover.md) now repeats the copy/identity and
  auxiliary verification under one exclusive permit and final transaction, then
  commits native ownership and its first Sync together. Queue retry retains that
  exact Sync. History contracts are written for Up,
  [Mercury](provider-mercury-cutover.md), [Brex](provider-brex-cutover.md),
  [Akahu](akahu-cutover-history.md) and
  [Enable Banking](enable-banking-cutover-history.md). Only Up currently declares
  native readiness; none has completed executable migration acceptance here.
  Shared cash-account source selection preserves existing
  policies and requires explicit choices for accounts with overlapping links.
  These paths and their tests have not executed; this is not activation acceptance.
- [Financial identity plans](provider-financial-identity-migration.md) cover all
  23 provider families, retaining exact source IDs, Entry UUIDs and typed financial
  snapshots. Plaid retains its specialized stream/alias planner. Both planners
  expose bounded candidate enumeration including blockers; final reconciliation
  must repeat the inventory from the beginning. Ambiguous idless occurrences and
  financial type transitions remain explicit blockers. Archive reads now accept
  byte/chunk bounds. The internal `Ingestion::IdentityBootstrap` publisher now
  consumes fresh plans under the actual exclusive legacy fence, commits evidence
  and progress atomically, and verifies from the beginning with exact identity
  state and forward/reverse inventory checks. Explicit restarts retain original
  proof. These paths have unrun tests; no evidence or data migration has executed.
- A shared transaction/balance/holding/activity sync engine with bounded captured pages, resumable
  replay, writer leases/epochs, source-policy checks, stale-run rejection and atomic
  ledger/evidence/checkpoint commits. Partial aggregator inventories retain usable
  records and allow independent account requests while reporting an incomplete run.
  Per-resource fetch progress is separate from completed coverage/checkpoints;
  budgeted history reads resume without authorizing absence pruning. Adapters
  can scope snapshot-specific progress to one logical Sync, preserving
  same-Sync attempts while restarting a new snapshot from completed coverage.
  The prior evidence and actual checkpoint admission checks remain intact.
  Shared inventory/activity regressions are written but unrun. Account
  scheduling favors the least recently covered transaction stream. Discovery may
  leave currency/balance unknown; no placeholder amount or currency is posted.
- Initial transaction history now has pure adapter policies instead of always
  receiving the generic 90-day fallback. Akahu requests accessible history with
  no start date; Wise uses 365 days or its configured account-creation/year-2000
  fallback. SimpleFIN preserves its 360-day initial target, one-calendar-year
  initial floor and 30-day repeat overlap, continuing every required page even
  when recent chunks are empty. Explicit dates retain precedence within applicable
  initial limits; those limits never narrow a completed-checkpoint gap.
  Declared account metadata affecting this choice is pinned before request
  admission. [Production-syncer tests](provider-history-windows.md) are written
  but unrun; other provider windows and legacy Sync/cursor transfer still need
  acceptance.
- [Binance retained history installation](binance-history-bootstrap.md) now writes
  a signed encrypted seed receipt after the exact copy and financial identity
  proofs are verified. Native requests pin the installed seed independently of
  activity continuation progress. Repeat installation preserves IDs, and retained
  proof blocks copier restart even if its checkpoint is lost. Tests remain unrun;
  the preparation coordinator installs and reverifies the seed through durable
  account receipts. Unlinked and unsupported topologies remain unresolved rather
  than acquiring fabricated input. Upstream coverage acceptance and activation
  remain gates.
- [SimpleFIN direct admission](simplefin-legacy-access.md) now guards importers,
  financial processors and link repair against changed item ownership and
  inconsistent financial links. Saved-source effects retain importer counters and
  discovery timestamps. Its [three deferred jobs](simplefin-deferred-job-fencing.md)
  also retain admission through ordinary failure recovery. Deferred holdings now
  carry signed original account/link, input, policy and Sync ancestry, revalidated
  before each write, including the credential revision. [Durable credential claims](simplefin-credential-claims.md)
  now commit reconnect intent and response separately, recover saved installation
  results and retain the original Sync for queue recovery. Ingestion and credential
  maintenance share the target session lock; automatic token retries remain off.
  Existing-item requests now have administrator retry and audited cancellation
  controls, with terminal state enforced in the journal and delayed jobs.
  Tests are unrun; old-job disposition, initial-connect recovery, observation-date handover,
  concurrent financial relinking and remaining lifecycle surfaces need acceptance.
- Existing accounting reconciliation/protections are reused by the ledger writer.
  Source records retain canonical input identities and resolved legacy identities.
  Withdrawn holds retain evidence and original Entry UUIDs after eligible deletion.
  Ordered observations cannot regress posted rows during overlapping history
  reads, and identical idless occurrences retain distinct stable mappings. Holding
  evidence preserves original Holding UUIDs, cost-basis locks and security choices.
  Security lookup precedes the fenced write transaction. Captured balance anchors
  use the observation date and reject replacement of a newer anchor.
  A run resumed from fetch progress cannot prune absent records until a fresh
  authoritative snapshot is obtained. Cash supplied through transaction and
  investment-activity streams shares source authority. Unreconciled cross-source
  holding handovers fail instead of reporting a successful unchanged position.
  Discovery currency hints cannot relabel cached amounts; a valued unit change
  clears omitted old-unit amounts. Distinct source position components cannot
  silently collapse into a single holding; explicit aggregation is required.
- Investment activity meaning and ledger representation are separate: an explicit
  `ledger_type` preserves historical Trade versus Transaction rows. Insert-only
  policies preserve prior financial values; notes, fees and narrowly permitted
  missing-label repair are supported. Atomic trade/funding pairs cannot recreate a
  missing legacy leg. Completed explicit transaction tombstones withdraw evidence
  and preserve user edits and other sources; unbackfilled legacy identities stop
  deletion. Connection-wide generations now capture and seal before financial
  application, publish bounded children, resume sealed failures and promote a
  single cursor after the child barrier. Grant/link revisions are pinned; unknown
  accounts/removals stop publication. Unlinked observations retain source identity
  without an Account binding, enabling later tombstone routing. First publication
  requires a fresh policy-bound batch; the financial binding then remains fixed.
  Newly linked historical replay is still a gate, recorded on the external account.
- Durable credential sessions commit an encrypted refresh intent before a
  single-use token exchange, commit replacement credentials before use, and leave
  interrupted exchanges requiring reauthorization. A committed request counter
  seeds from archived Kraken nonce state. These protocols still require every
  legacy consumer of the same grant/API key to join the cutover boundary.
  Exchange-rate lookup returns exact values with actual market dates for capture.
  Explicit deployment-credential bridges select Plaid's regional configuration,
  SnapTrade's OAuth application and Indexa's existing token fallback without
  exposing secrets as runtime options. Plaid environments must be pinned before
  activation. These bridges preserve existing settings while setup UI is migrated.
  The row copier now places Trading 212/Trade Republic item currency in native
  connection settings, and SnapTrade expiry/scope/token type beside its encrypted
  tokens. Original typed archives and checkpoints remain intact. Ordinary and
  retained verification compare these runtime projections; old incomplete copies
  require explicit recopy or reconciliation. Copy-to-consumer and retained-copy
  rejection tests are written but unrun. These projections do not establish
  history coverage, authorization ownership or activation readiness.
- [Retained runtime inputs](provider-retained-runtime-inputs.md) now supply Trading
  212 instruments, Wise copy-time history policy and Monobank boundaries/oldest
  pending time from verified quiesced archives. Full inputs are frozen; compact
  provenance and account-binding checks detect drift before requests/publication
  without repeatedly parsing historical payloads. Shadow copies cannot seed these
  inputs. Tests are written but unrun; input transfer does not establish coverage
  or replace provider-specific continuation and lifecycle acceptance.
- Family scheduling selects unmigrated legacy items or eligible shared connections
  from one inventory. Paused transitions schedule neither owner; retired legacy
  data leaves shared sync, credentials and account routing enabled. Sync history
  includes both owners, including disabled connections. This is scheduling and
  visibility only: previously queued work still requires legacy execution fencing.
- Ordinary account pages now capture their source link, account identity, policy
  and authorization revisions before HTTP, and recheck them under ordered locks
  at publication. This includes first observations without existing EntrySource
  mappings. A missing captured binding is rejected rather than reconstructed at
  publication; generation children retain the exact sealed binding. Financial
  account currency/type changes invalidate outstanding captures.
  Exact tombstones and pending absence use current-versus-retired identity
  resolution, lock entries before checking protection, and retain field-locked
  or statement-reconciled financial records. They also preserve transfer legs and
  fees, splits, receipts, goal/recurring associations, rejected matches and shared
  historical entryables instead of cascading through those relationships. These
  [withdrawal protections](provider-pending-settlement.md) have authored but unrun
  exact-removal and complete-pending-inventory regressions. Old pending aliases withdraw only
  their observations. Reviewed Plaid identities need no compatibility-column
  rewrite to support removal. [Permanent migration identity evidence](financial-identity-evidence.md)
  now validates original UUID/alias proofs after later observations replace the
  current batch. Capture checks the actual legacy permit and financial snapshots;
  nonblocking financial locks defer to in-flight edits. Database guards preserve
  the proof through Entry deletion. A transaction-scoped cache avoids repeated
  parsing of the same signed batch while checking persisted status on every call.
  Explicit versioned signing keys now retain verification of older financial
  attestations across signer rotation, with a separate opt-in legacy signature
  policy. Publisher, final sweep and signing tests are unrun; key deployment,
  archive-checksum key rotation, trigger restoration and coordinated cutover
  re-verification remain gates.
- [Request grant capture](provider-request-grants.md) pins the credentials and
  authorization context used to build an adapter, verifies it before HTTP and
  publication, and records only explicitly accepted refresh/cookie transitions.
  Ordinary and grouped responses retain encrypted grant evidence. Balance updates
  use the exact external-account UUID/namespace; an eligible busy lease defers
  its successor. Declared factory inputs and per-request account Record, window
  configuration and checkpoint evidence now have separate proofs checked before
  HTTP/publication. Tests remain unrun, and deployment-wide credential revisions
  and realistic inventory/lock-contention benchmarks remain activation gates.
  Resumable activity groups now retain session-rotation receipts atomically with
  credential saves, including rotations before a failed group capture. Exact
  request-prefix ownership, lease checks and explicit receipt references support
  proof verification on an admitted same-Sync retry. A separate live execution
  capability now guards ordinary credential reads/writes as well, without changing
  replay evidence. Protocol tests and job recovery remain unverified.
- Native imports lock and revalidate manual duplicate candidates before adoption,
  reject conflicting locked cash/trade economics or transaction metadata atomically,
  and preserve reconciled entries and descriptive locks. Transaction creation,
  updates and tag edits plus trade updates commit financial edits and protection
  flags together. Entry-triggered account scheduling waits until those transactions
  commit, avoiding the opposite Account/Entry lock order in API/assistant callers.
  The new behavioral/concurrency tests remain unrun. Remaining edit surfaces,
  including API trade protection, still need acceptance before activation.
- [Deferred provider work](provider-sync-continuations.md) retains the Sync UUID,
  encrypted fetch progress and original observation date across scheduled attempts.
  Completed independent streams are reused; cancellation and the provider's own
  work barrier prevent premature parent completion. Tests and delayed export
  integrations remain unverified. No worker sleeps while an export is prepared.
- Native execution admission now commits Sync start, a separate execution revision
  and the connection lease together. Expired-worker recovery preserves logical
  fetch identities; obsolete workers cannot fail, defer, finish or release a newer
  execution. The cleaner schedules bounded recovery, and finalization-only retries
  preserve the writer epoch for pending investment children. Ordinary child enqueue
  and IBKR handoff dispatch now recheck the fence after preparation. Post-sync
  database work has a transactional completion marker; external broadcasts may
  repeat after rollback. The new migrations and behavioral tests remain unrun.
  These are shared recovery mechanisms, not provider-specific replay acceptance.
  IBKR's [sealed historical handoff](provider-ibkr-export-protocol.md#sealed-account-scheduling)
  now retains the same capture/child across worker changes, including capture
  before enqueue. Its original grant and selected sealed account input govern
  historical publication; older proof-less snapshots retain strict epoch checks.
  Those focused tests are also unrun.
- Trade Republic activity transport failures have a five-retry generation budget
  with exact request-position and session-receipt verification before same-Sync
  deferral. Timeout/transient classifications and validated `Retry-After` survive
  sanitized transport errors; authentication, malformed data, ownership failures
  and explicit limits do not gain an automatic transport retry. Full-job tests and
  the counter migration remain unrun.
- [Legacy writer fencing](legacy-writer-fencing.md) protects common sync dispatch
  with a shared advisory lock keyed before control creation. Exclusive acquisition
  can drain that boundary. Explicit guards also protect 46 public import/processing
  methods on all 23 item classes, including complete validation and fresh reloads
  of Onchain/Sophtron account subsets. Direct processors, lifecycle operations,
  credential consumers and post-sync repairs remain before cutover is safe.
  Shared destruction jobs now retain the exact legacy item/account permit through
  ordinary failure recovery, so deletion-flag reset cannot escape its ownership
  boundary. [Shared lifecycle admission](provider-shared-lifecycle.md) now acquires
  a complete multi-item permit for legacy account unlinking and Family destruction,
  followed by row locks and an exact source inventory recheck. Failed cleanup has
  its own savepoint; family restrictions precede remote callbacks. These tests are
  also unrun. Direct financial Account destruction, generic link writers, family
  financial-data reset and native lifecycle commands remain unfinished.
- IBKR historical handoff now seals encrypted inputs onto serialized account jobs,
  captures trade FX before publication, and atomically applies opening repair,
  materialization and equity history. A completion marker prevents repeated
  financial work after worker recovery. Behavioral and database-trigger tests are
  written but unrun; direct-call auditing, trigger restoration, parity and queued
  edit throughput remain explicit [acceptance gates](provider-historical-balances.md).
  Its [auxiliary logo copier](provider-ibkr-auxiliary-transfer.md) now archives and
  verifies exact bytes and attachment metadata while retaining the original blob.
  Preparation now captures it before identities and repeats a read-only byte sweep
  after fresh copy/identity verification, retaining its original checkpoint even
  for a connection with no accounts or no logo. Parent/child interruption and lost
  receipt tests are written but unrun.
  The legacy financial caches are already covered by the main row manifests;
  original Flex XML was not retained by the legacy importer. Auxiliary tests and
  the coordinated quiesced comparison remain unverified.

The explicit operator entry points are `bin/rails provider_data:status` and
`bin/rails provider_data:copy`. The latter enqueues bounded copy/verification jobs;
optional `PROVIDER` and `FAMILY_ID` filters narrow the scope. It does not run schema
migrations, switch writers, delete legacy records or complete the migration.

## Native provider ports

All providers below have executable source-column manifests. A provider is complete
only when its full native pipeline, data migration, lifecycle and parity checks pass.

| Provider | Native implementation / outstanding acceptance |
| --- | --- |
| Up | Adapter, bounded transport, transaction/balance writer and tests exist. [Legacy direct consumers and Up-specific lifecycle boundaries](up-legacy-writer-fencing.md) acquire ownership. The [explicit cutover command](provider-up-cutover.md) verifies retained data, checks cached history, commits ownership with one native Sync and supports queue recovery; the existing manual-sync route resolves the exact migrated owner. [Shared native settings](provider-native-configuration.md) now handle names, history dates and static token replacement without rewriting legacy evidence. [Shared native setup](provider-native-account-setup.md) preserves existing source authority and original copied evidence. Tests are unrun. Remaining setup/retirement workflows, unresolved cache dispositions, deployment drain and executable acceptance remain gates. |
| Mercury | Adapter and bounded transport written. [Direct legacy publication](mercury-legacy-writer-fencing.md) holds the migration permit across HTTP, snapshot writes, processing and scheduling. [Lifecycle commands](mercury-lifecycle-admission.md) bind signed picker forms to their original connection, recheck account/admin access and route manual sync to the exact owner. [History verification](mercury-cutover-history.md) checks original cached financial versions and supplies account-specific first-read dates. The [shared cutover path](provider-mercury-cutover.md) preserves explicit source selections and atomically commits ownership, history hints and one recoverable native Sync. [Financial parity cases](mercury-financial-parity.md) cover liability signs and status transitions, including secondary observations across authority switches; booked observations cannot regress to pending. [Shared native settings](provider-native-configuration.md) support static token replacement while preserving the original endpoint and legacy evidence. Tests remain unrun and readiness remains false. Unresolved cache dispositions, native retirement, endpoint transitions, rollback and executable acceptance remain gates. |
| Brex | Adapter and bounded transport preserve aggregated card identity, signed balances and available credit. [Direct legacy publication guards and history verification](brex-cutover-history.md) check original credentials, source/cache/account ownership and signed cash/card financial evidence. [Lifecycle commands](brex-lifecycle-admission.md) bind picker actions and targets, recheck permissions, serialize credential replacement and route manual sync to the exact owner. [Shared cutover](provider-brex-cutover.md) preserves source choices and atomically installs account-specific history bounds, ownership and one recoverable Sync. Cash and company-card coordinator tests cover first native replay, retained UUIDs, independent windows, failure rollback and queue recovery. [Shared native settings](provider-native-configuration.md) allow static token replacement while preserving the endpoint and legacy evidence. [Shared native setup](provider-native-account-setup.md) declares its cash/card types while preserving the activation gate. Tests remain unrun and native readiness remains false. Unresolved cache dispositions, native disconnection, rollback, upstream coverage and executable acceptance remain gates. |
| Akahu | Adapter and bounded transport written; initial requests preserve unbounded accessible history through the shared syncer. [Retained-history verification and gated cutover](akahu-cutover-history.md) require exact cached financial proof, preserve configured dates and retain explicit nil first-read boundaries. Shared preparation preserves source choices. [Direct legacy admission](akahu-legacy-admission.md) covers import, snapshots, financial publication, Sync progress and browser lifecycle, with complete pending-inventory receipts, signed account selections, atomic authorized disconnect and shared manual-sync routing. [Source-proven pending settlement](provider-pending-settlement.md) retains the original Entry UUID and signed migration identity through posted updates and pending replay. Collision-free idless pending originals retain their signed zero occurrence; mapped idless hashes refuse monetary-unit changes. [Native lifecycle](akahu-native-lifecycle.md) declares both-token configuration, subtype/Investment-cash setup, saved routes and reviewed retirement. Migration-to-native suites cover stable/protected identities, complete/failed pending pages, balances, currency transitions, merchants and first history windows. Tests remain unrun and native readiness is false. Ambiguous idless suffix/occurrence disposition and executable history/pending/currency/lifecycle acceptance remain open. |
| Wise | Native readers/normalizers and tests written; shared initial requests preserve the 365-day or configured all-history boundary. [Retained account-history policy](provider-wise-retained-history.md) supplies verified cutoffs and flags; committed statement postings retain promotion evidence for later factories. The [profile statement barrier](provider-wise-statement-barrier.md) stages and reuses first-window responses, preserves same-Sync inputs, treats successful-empty/unlinked success as a fallback veto, and keeps fallback coverage and initial retry boundaries unchanged. [Interbalance finalization](provider-wise-interbalance-transfers.md) now joins exact committed event pairs under current source authority, preserving existing/protected decisions and allowing a still-valid older counterpart. Deferred streams postpone pair review; ordinary transport failure still terminalizes the job. Tests remain unrun. Ambiguous topology/older unproved events, explicit promotion reset, coverage acceptance and lifecycle/cutover remain activation requirements. |
| SimpleFIN | Native readers/normalizers, initial-history/overlap policies, bounded pagination, captured credit classifier and holdings persistence written. [Direct legacy publication](simplefin-legacy-access.md) locks and revalidates account/link context, with savepoints and security resolution outside row locks. Source-scoped pending cleanup checks retained identity/protection evidence and reports after commit. [Deferred holdings](simplefin-deferred-job-fencing.md) bind inputs, target, policy, credential revision and Sync ancestry. [Durable claims](simplefin-credential-claims.md) cover connect/reconnect intent, saved-result installation and same-Sync dispatch recovery; ingestion/maintenance share credential serialization. [Fresh transaction evidence precedes sparse-history balance classification](simplefin-native-balance-inputs.md), preserving original baselines and replay proofs. [Quiesced copies retain classifier hints and expiry](simplefin-retained-classifier-hint.md). Tests remain unrun. Cleanup performance/large-cache acceptance, old-job disposition, observation-date handover, initial-connect recovery UI, acceptance of existing-item retry/cancellation, generic link mutations, older archives without hint capture, full legacy/history parity and lifecycle acceptance remain. |
| Enable Banking | Native consent-scoped readers/normalizers and [direct legacy admission](enable-banking-legacy-admission.md) retain original consent, source/cache/link and Sync ownership. [Consent lifecycle admission](enable-banking-consent-lifecycle.md) now records single-use exchanges and upstream revocation intent, with signed callback state and local publication locks. [Native inventory publication](enable-banking-authorization-inventory.md) binds account outputs to their captured consent, commits exact membership additions and constructs the next request factory without changing original evidence. [Cutover history](enable-banking-cutover-history.md) verifies cached rows against signed financial identities and the exact copied consent/memberships; a missing configured floor requests all accessible history, and a narrowed upstream window cannot advance coverage. Shared source selection/cutover are wired behind disabled readiness. Tests are authored but unrun. Signed legacy setup/linking, native consent renewal/status/revocation management, uncertain revocation reconciliation, authorization-aware retirement, performance and complete end-to-end migration acceptance remain gates. |
| Lunch Flow | Native readers/normalizers and tests written; separate balance endpoint, downstream institutions and idless occurrences represented. [Late idless pending observations](provider-lunchflow-late-pending.md) retain same-source evidence without creating duplicate posted entries. [Forward pending settlement](provider-pending-settlement.md) now uses unique source-proven candidates, preserving native and signed legacy UUIDs, protected fields and retired aliases. Tests remain unrun. Future evidence retirement/removal, protected pending-display semantics and lifecycle acceptance remain gates. |
| Monobank | Native readers/normalizers and tests written, including exact account/operation FX, physical-request budget and resumable history. [Retained history input](monobank-retained-history.md) now supplies exact copied boundaries and oldest-held time with UUID/namespace/account binding. Expiry policy, full history/lifecycle acceptance and cutover remain. |
| Plaid US/EU | Native readers/normalizers, connection-wide capture/restart/seal/fanout/cursor barrier, typed account enrichment, explicit legacy category matching and tests written. Identity transfer planning, resumable evidence publication and mapped-entry resolution are written but unrun. A [deployment binding](provider-plaid-deployment-binding.md) retains copy-time environment/application provenance. Migration preparation now captures and verifies the [signed cached-change journal](plaid-cached-change-journal.md), including original ordering, duplicate observations, blockers, authority and child/parent retry. Explicit unambiguous pending Entries can retain only their current ID despite an unapplied cached settlement; new preparation and fresh-publication tests preserve the UUID and protected baseline. This does not apply cached financial changes or accept the copied cursor. Fresh initial-generation handoff, cache-only discrepancies, missing item-wide coverage evidence, newly linked history replay, webhooks and runtime parity remain gates. Both offerings share one relational provider key. |
| Sophtron | Native readers/normalizers and tests written; legacy polling, ingestion/scheduling, credential/discovery and settings/lifecycle commands now acquire migration ownership, with [unrun boundary tests](sophtron-legacy-refresh-fencing.md). Signed picker selections bind the exact displayed item and connection context through link/setup submission. Generic parent/link operations, concurrent legacy credential changes, native remote refresh/job/MFA lifecycle and manual sync policy remain gates. Insert-only cash writes are supported. |
| Redbark | Native readers/normalizers and tests written; bounded offset pages split truncated date windows. Banking and document sources retain distinct balance support. [Source-proven pending settlement](provider-pending-settlement.md) now preserves native and signed legacy Entry UUIDs through posted updates and pending replay. Tests remain unrun; migration, protected pending-display semantics and lifecycle acceptance remain. |
| Indexa Capital | Native holdings reader and cached-activity normalizers written. Live activities remain unsupported by the existing integration. Security identity/name repair, unavailable prices, application credential fallback and lifecycle require acceptance. |
| IBKR | Native readers, strict parser, exact export restoration, historical-equity capture/handoff, sealed account-sync inputs, serialized materialization, atomic anchor/history application and logo archival are written with unrun tests. Preparation now captures the connection-scoped archive and independently reverifies its bytes after identities. Shared delayed polling and this coordinated verification are untested. Source snapshot handover acceptance, trigger restoration and financial/queue parity remain gates. |
| Questrade | Native readers/normalizers, bounded history, currency-specific cash holdings and typed activities are written. [Unpriced trades retain their commission and retry window](questrade-incomplete-trades.md); [activity identifier encoding](questrade-activity-identities.md) preserves legacy JSON-number hashes and financial UUIDs. [Credential sessions and handover admission](provider-questrade-legacy-credentials.md) serialize legacy consumers, retain refusal before single-use exchange, and block both migration preparation and native factories from accepting an uncertain archived token. Native exchange tests cover replacement commit before data and preservation of original credentials. [Publication admission](provider-questrade-legacy-publication.md) rechecks source/cache/link ownership inside short financial locks. [Durable activity requests](provider-questrade-activity-requests.md) retain original context, dates and revision through queue failure, cancellation and recovery; active or unidentified work blocks quiescence. Failed reads cannot become completed empty history. The request and checkpoints join the copy manifest. Tests and the additive migration remain unrun; readiness remains false. Link lifecycle/retirement, native reauthorization, full credential-transfer acceptance, cached fallbacks, identifier ambiguity, history and native cutover remain gates. |
| SnapTrade | Native OAuth readers/normalizers and tests written; deprecated-only credentials require reconnect while originals remain archived. Rotation ownership/expiry bootstrap, authorization discovery, partial cash/history completeness and lifecycle require acceptance. |
| Trade Republic | Native restored-session readers, account/holding normalization and a [connection-wide timeline barrier](trade-republic-native-port.md) are written with unrun tests. Both topics stage bounded pages/details once before publishing children and promoting one checkpoint. Same-Sync replay retains source bindings and credential chains. The retained portfolio collector now routes exact remote ownership to existing copied `portfolio`/`cash` IDs and supplies prior quotes with provenance, preserving financial UUIDs and holding identities. Topology/quote and receipt/crash acceptance remain unverified. Historical timeline-cache reprocessing, financial relocation, complete holdings and lifecycle/performance remain gates. |
| Trading212 | Native readers/normalizers and tests written; ticker identity and throttled history represented. [Retained instrument catalog](provider-retained-runtime-inputs.md) now reaches the actual factory and failed-refresh fallback. Catalog, activity/holding parity and lifecycle require runtime acceptance. |
| Coinbase | Native readers/normalizers, explicit copier projection and tests written. Crypto quantities remain distinct from fiat valuations; new archives retain the copy-time monetary baseline. [Exact retained buy/sell reconciliation](coinbase-legacy-trade-identities.md) now connects modern transaction IDs to signed original postings through captured provider relationships, preserving Entry/Trade UUIDs and user edits. Tests remain unrun. Missing or ambiguous relationships, old archives lacking required baselines, native cached valuation fallback, lifecycle and performance/parity acceptance remain gates. |
| Binance | Native readers/normalizers and tests written, including combined account, partial source snapshots and atomic P2P pairs. The [retained history plan, installer and verifier](binance-history-bootstrap.md) account for every cached trade and both P2P legs, verify permanent financial identity proofs and retain signed starting input for native requests. Preparation now installs and independently reverifies that input; unresolved rows block installation, and unsupported topologies retain explicit dispositions. Tests remain unrun. Upstream coverage acceptance, lifecycle/activation, non-combined topology and explicit aggregation of disjoint holdings components remain gates. |
| Kraken | Native readers/normalizers and tests written; atomic nonce dependency, captured FX/asset valuation and bounded history represented. Same-key legacy coordination, partial/cached valuation disposition and lifecycle require acceptance. |
| CoinStats | Native wallet, exchange-asset, portfolio and DeFi readers/normalizers, typed encrypted source descriptors, copier verification, partial balance staging and captured valuation dates written. Async wallet readiness, complete portfolio-to-holdings handoff, missing valuation disposition and representation/lifecycle migration remain gates. |
| On-chain wallets | [Durable capture and assembly](provider-onchain-capture.md) connect the actual factory to bounded Bitcoin/EVM/Solana reads, immutable snapshots and exact-day crypto quotes. Same-Sync replay restores captured responses; a new Sync restarts snapshot-specific progress. [Pinned FX acquisition](provider-onchain-fx-acquisition.md) supports Twelve Data, Frankfurter, [MOEX dated history](provider-onchain-moex-fx.md) and Yahoo alongside existing rates. Yahoo cookie/crumb/chart steps now use exact durable same-Sync authentication references, bounded refresh/inverse branches and expiry checked after pacing; replay retains the original rate date. Tests are unrun. Undated MOEX current quotes remain deliberately unsupported. FX parity, quota coordination, lifecycle, performance and acceptance of the legacy display-only Transaction-to-Trade transition remain gates. |

## Remaining shared implementation

[Retained account ownership indexing](provider-retained-account-index.md) now
records each encrypted account archive version's historical financial and link
UUIDs, including superseded copies. The copier captures and verifies receipts;
copy finalization, retained verification and preparation reject unindexed chunks.
Existing archives have a bounded, explicit family-scoped backfill. These tests and
the migration remain unrun. This supplies reverse discovery for lifecycle work;
it does not itself implement account destruction or retirement.

[Original generation ownership](provider-generation-account-index.md) now has a
separate indexed projection, including detached accounts captured before fanout.
New transaction/activity generations populate it; older NULL projections require
explicit verified backfill. A read-only financial deletion graph captures splits,
transfer fees/counterparts, pledges and statement ownership witnesses. Both are
groundwork with unrun tests. Complete source-owner discovery, lock/admission and
deletion integration remain unfinished; neither is deletion authority. Historical
encrypted-context decompression and large-account graph limits need acceptance.

[Account source discovery](provider-account-source-inventory.md) now joins current
links and retained evidence across legacy, native, dual and document sources,
including detached captures and calculation history. Its read-only diagnostic
task reports owner identities. [Historical command bindings](provider-historical-command-bindings.md)
now project both original policy owners and the source batch, with fresh capture,
transparent Plan/Writer retry indexing and explicit bounded backfill. Their database
guard preserves the original capture. Tests and migration remain unrun; unindexed
commands and deleted secondary policies remain explicitly unresolved. Complete
lifecycle admission is still required before this inventory can authorize a mutation.

[Retained financial account identities](provider-retained-financial-account.md)
now preserve original source/evidence UUIDs independently of the live Account FK.
Source selection or first publication captures identity; existing bound observations have a transactional
FK-transfer migration, and database guards prevent rebinding and resurrection.
Account destruction refuses retained observations or policies before callbacks rather than
cascading evidence. [Source-policy retention](provider-source-policy-retention.md)
now captures original legacy/shared owners, preserves inactive revisions after link
removal, and verifies one-way copier enrichment without rewriting history. Unknown
revisions remain unresolved. Legacy unlink deactivates unused captured selections
and preserves their ownership through tracking cleanup. Tests and migrations remain
unrun. The admitted retirement command, statement disposition, scheduling and
recovery remain unfinished; this does not complete native Account deletion.

[Account calculation admission](provider-account-sync-admission.md) now rechecks
live ownership before queue input reads, worker recovery/sealing, publication and
post-sync finalization. Unavailable jobs preserve existing seals and completion
markers without dispatching more work. Market-data preparation remains outside
publication locks. [Calculation ownership and retirement retention](provider-account-sync-retention.md)
now capture the original family, transfer input ownership without replacing Syncs,
protect retired executions/selections from dependency cascades and separate internal
history from live user permissions. Ordinary empty-job cleanup remains available;
reset explicitly refuses retired identities. Tests and migration are unrun.
The admitted retirement command, coordinated native erasure, complete FX preparation
parity and provider-specific lifecycle acceptance remain required.

[Native account unlink](provider-native-account-unlink.md) now shares current
ownership admission across native, migrated dual and legacy sources. It preserves
native financial/copy evidence and original policies, removes only current links
and holding references, and clears live calculation-source selection. New IBKR
handoffs recheck the original link/policy under Account locks before selecting a
child, closing the capture-to-unlink race. Behavioral and concurrency tests are
written but unrun. Wise, Trade Republic and Binance retained-input collectors now
recognize fully detached original sources while keeping archive/receipt validation,
rejecting replacement links and excluding the former owner's financial inputs.
Trade Republic retains remote aliases for still-linked sibling routing. Shared
connection deletion, native Account retirement, relinking
and provider-specific lifecycle acceptance remain unfinished.

1. Native checkpoint translation, auxiliary-table/attachment migration, deployment
   credential references, and explicit disposition of malformed legacy rows.
2. Complete legacy-writer fencing and deployment drain, integrate quiesced
   re-verification with auxiliary/identity/checkpoint proofs, atomic cutover, forward/reverse
   rotating-credential transfer, rollback and retirement. Archived `legacy_state`
   checkpoint values are not yet executable native stream checkpoints.
3. Execute and integrate acceptance for the written
   [connection-wide change-set staging and cursor promotion](connection-change-sets.md),
   and extend newly linked account replay beyond the bounded native transaction
   contract, remaining security identifier policies, historical balances, provider removal protocols,
   complete-snapshot holding replacement and provider-specific protocol needs
   surfaced by the native ports; no legacy importer/processor wrappers
   should be counted as completed native migrations.
4. Remaining providers' shared setup/reauthorization, source-specific unlink UI and connection deletion,
   webhook routing, queued-job compatibility,
   support/export/reset tools and existing UI/API integration. Native links now
   have a common account-facing adapter; the full lifecycle is still incomplete.
5. Import-cleanup rule revisions/evaluation/UI and statement-backed PDF convergence
   described in the linked refinements. Their schema/value groundwork does not
   constitute a working rules hook or a migrated PDF publication workflow.
6. Execute migration, model, adapter, failure/concurrency, all-provider parity and
   full repository checks in a working Ruby/PostgreSQL environment. Ruby/Bundler
   are currently unavailable here; authored tests have not been executed. Static
   `git diff --check` and schema-manifest inventory checks are the checks performed.

Use the [migration matrix](bank-data-provider-migration-matrix.md),
[source/rules refinement](account-data-and-import-rules.md) and
[multiple-source/statement requirements](multi-source-ingestion.md) as acceptance
requirements. Completion requires evidence for every row and lifecycle gate, not
only the presence of these files or a successful shadow copy.
