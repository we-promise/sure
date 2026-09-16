# Akahu retained history and cutover admission

Status: implemented contract and authored tests, not executed acceptance. Akahu's
native readiness remains false. Registering its history verifier does not enable
production cutover, and no existing connection has been switched here.

## Preserve financial identities before handover

[`Akahu::CutoverHistory`](../../app/models/provider/account_data/akahu/cutover_history.rb)
runs inside the final cutover transaction while the caller holds the exclusive
legacy item permit. It verifies the exact family, disabled connection, original
quiesced migration control, complete copied account inventory, retained cache,
configured start dates and original account links. Reads have account, row,
ciphertext, archive and financial-proof byte limits.

Each stable-ID cached transaction must have authenticated migration evidence
pointing to the existing Entry UUID. The captured original amount, currency, date,
description, notes and Akahu metadata must agree with the normalizer. Comparison
uses the original financial snapshot, preserving later user edits. A signed
retired pending alias can account for an old pending cache row; a settled row
cannot borrow that suppression. Missing postings, current pending-state drift,
withdrawn observations, malformed or repeated IDs and nonempty unlinked caches
require explicit disposition. The verifier never creates financial rows.

The shared [`MigrationHistoryProof`](../../app/models/provider/account_data/migration_history_proof.rb)
now authenticates the source/account/copy tuple, retained financial identity and
bounded proof batches for Up, Mercury, Brex and Akahu. Provider-specific cached
version and history policies remain with their adapters. Akahu's explicit legacy
normalizer matches the former processor's conversion of cached Float amounts;
new API normalization continues to require exact monetary values.

An idless pending hash may now migrate when it occurs exactly once in the original
cache, has no persisted suffix family, and its authenticated identity retains the
same external ID, input external ID and zero occurrence. The normal cached-value
and financial-identity checks still apply; a hash alone is not proof.
[`PendingIdentity`](../../app/models/provider/account_data/akahu/pending_identity.rb)
reuses that original mapping during native publication, including after settlement
has withdrawn the pending alias. Late replay reaches the retained alias instead
of allocating a duplicate suffix. An explicit withdrawal is not a retired alias
and still requires disposition before reuse.

Akahu's synthetic hash omits currency. Native publication therefore also checks
the authenticated original financial currency for migrated idless observations,
or the resolver-verified Entry currency for native mapped observations. A later
account balance in another currency cannot silently reinterpret an existing hold.
An explicit original transaction currency remains valid; an ambiguous fallback to
the new account currency refuses publication. Stable provider IDs retain their
existing correction semantics, and unmapped observations gain no inferred mapping.

Persisted collision suffixes and repeated indistinguishable cache occurrences
remain unresolved. A suffix allocated against earlier transactions does not
establish its position in a new response. Those caches refuse cutover; a second
incoming occurrence cannot borrow a migrated base's signed zero occurrence.
The [identity regressions](../../test/models/provider/account_data/akahu/pending_identity_test.rb)
cover migration, settlement, late replay, protected edits, explicit withdrawal,
ambiguous occurrences, currency transitions and corrupted original proof. They
are authored but unrun.

## First native acquisition

Each account's configured date takes precedence over the item's configured date.
With neither, the first native request deliberately rereads all accessible Akahu
history. The legacy importer used a seven-day overlap from item success when a
cache was nonempty; that timestamp does not prove complete account or pending
coverage and is not adopted as a native checkpoint.

The verifier returns every external account ID, including an explicit nil for
unbounded history. Cutover rejects missing/foreign account results and invalid
boundary types before changing ownership. Akahu nil values survive both account
metadata and the cutover receipt, distinct from an absent account result.
`akahu_initial_history_start` is a declared adapter input, so the existing request
input proof pins its value before acquisition and checks it before publication.
Posted and pending pages still use the native completion protocol.

Preparation uses the shared transaction/balance source-selection contract. It
preserves existing explicit selections and installs missing defaults only for an
unambiguous single link. Multiple links require explicit source choices. This
does not enable source switching or cross-provider transaction reconciliation.

## Remaining activation gates

[Direct legacy admission](akahu-legacy-admission.md) now covers the importer,
item/account snapshots, financial processors and coordinator, including original
account/link checks and complete pending-inventory receipts. Behavioral tests are
written but unrun; currency-transition and full parity acceptance remain open. Legacy
browser credential replacement, discovery, signed account selection, atomic
unlinking and deferred deletion now use lifecycle admission.
[Shared native configuration/setup, saved routes and retirement](akahu-native-lifecycle.md)
are now implemented behind the unchanged readiness gate. A real migration-to-native
publication suite covers liability signs, Investment cash, merchant metadata,
currency, stable/pending identities and initial history windows. Those tests,
ambiguous idless occurrence disposition, currency-transition cases and complete
pending/history behavior still need executable parity acceptance.

Focused tests cover real copying and financial identity bootstrap, immutable
history verification, explicit and unbounded dates, pending aliases, refusal and
limits, plus preparation/cutover with readiness overridden only in the test. The
Up/Mercury/Brex suites continue to cover their provider policies through the shared
proof helper. Ruby/Bundler are unavailable in this workspace, so these tests remain
unrun. See [implementation status](provider-implementation-status.md) for the
remaining all-provider migration work.
