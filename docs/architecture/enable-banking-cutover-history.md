# Enable Banking retained history and cutover

Status: implementation and behavioral tests are authored, with executable
acceptance still outstanding. Native readiness remains false. No connection has
been activated, no provider request has run, and no migration has been executed
as part of this work.

## Ownership and cached financial evidence

[`EnableBanking::CutoverHistory`](../../app/models/provider/account_data/enable_banking/cutover_history.rb)
runs within the final cutover transaction under the exclusive legacy item permit.
It requires the original family, quiescing migration control at epoch zero,
disabled shared connection, and unchanged copied item/account inventory. A
pending authorization attempt, unusable session, changed credentials, changed
account routing or changed authorization membership refuses handover. Reads have
account, record, stored-cache, archive and financial-proof byte limits.

Application credentials remain on the shared connection. The institution session
remains on its exact copied `ProviderAuthorization`, with explicit active
`ProviderAuthorizationAccount` membership. The stable legacy account identity may
differ from the API account UUID; both and the retained identification aliases
must agree with the original copy. Duplicate routing aliases cannot select an
arbitrary account or consent.

Every cached transaction needs the authenticated original financial identity from
[`MigrationHistoryProof`](../../app/models/provider/account_data/migration_history_proof.rb).
The gate compares original amount, currency, date, name, notes and Enable Banking
metadata against the legacy-compatible normalizer. It preserves Entry and
Transaction UUIDs and subsequent user edits by comparing the signed original
snapshot. A matching live Entry without signed bootstrap evidence is insufficient.
Missing, malformed, duplicate or unapplied cached rows refuse. Empty unlinked
accounts can remain discovery records; unlinked accounts with cached transactions
require explicit disposition before cutover.

Legacy IDs use `transaction_id`, then `entry_reference`, then the exact historical
content digest. Cached Float amounts retain their historical identity text before
explicit decimal conversion. Current pending identities must retain their signed
pending state. Booked rows that omitted `pending: false` remain valid, but a cached
`PDNG` row processed without the legacy `_pending` marker cannot claim booked
financial parity. An authenticated retired `auto_claimed_pending_ids` alias can
dispose of a cached pending row. Manual-merge-only suppression has no such signed
alias and does not authorize omission. A posted alias cannot borrow pending
suppression, and withdrawn evidence requires disposition.

The verifier never imports a cache, modifies financial rows, or infers deletion
from an empty cache. Native Enable Banking transaction pages continue to declare
`pending_absence_authoritative: false`.

## First native acquisition and partial history

The item's configured `sync_start_date` remains the explicit floor. Otherwise the
gate returns an explicit nil for every copied external account, requesting all
history the provider can supply. Legacy Sync success and copied consent-expiry
state never become a transaction coverage checkpoint.

The shared cutover command retains these values in its receipt and in
`enable_banking_initial_history_start` account metadata. The adapter declares that
metadata as a request input. Explicit nil survives to `date_from: nil`; a date
remains the configured floor. Connections without this metadata keep the existing
90-day default. Current explicit settings and completed native checkpoints retain
their usual precedence over an initial hint.

If the provider narrows the requested period, the adapter carries
`history_complete: false` through BOOK continuation pages and the pending phase,
including the pending-unsupported terminal response. Reaching the last page does
not restore history completeness. The shared runtime may retain and publish the
observations it received, but cannot advance `covered_through` as though the
original range had been read in full.

## Verification and remaining limits

The [28-case history suite](../../test/models/provider/account_data/enable_banking/cutover_history_test.rb)
uses [real migration fixtures](../../test/support/enable_banking_migration_test_helper.rb):
legacy financial import, verified copying, signed identity bootstrap, preparation,
and cutover/replay with readiness overridden only in the relevant tests. It also
checks consent routing, protected financial records, refusal paths, bounded reads,
initial request dates and narrowed-page propagation. The
[authorization inventory suite](../../test/models/provider/account_data/enable_banking/authorization_inventory_test.rb)
covers shared native consent membership and checkpoint behavior.

Ruby/Bundler are unavailable in this workspace, so these tests remain unrun.
Passing the implemented gate is not operational acceptance of the native port.
End-to-end provider execution, lifecycle/browser flows, financial parity across
account types and institution-specific history/consent responses still need
runtime verification before readiness changes. This slice does not implement
cross-provider transaction matching, reinterpret manual merges, or guarantee
history beyond the range the institution actually exposes.
