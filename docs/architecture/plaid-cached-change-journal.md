# Durable Plaid cached-change journal

Status: implemented with unrun behavioral tests. Preparation now records and
verifies every page of the [cached-change plan](plaid-checkpoint-bootstrap.md)
before reporting `awaiting_acceptance`. This records observations, not acceptance
of financial changes or the copied Plaid cursor. No migration has been executed.

## Publication and preservation

`Provider::AccountData::Plaid::CachedChangeJournal` uses one connection-scoped
`legacy_plaid_cached_changes` checkpoint and immutable encrypted migration batches.
Each invocation captures or verifies one bounded planner page. The journal enters
the exclusive legacy fence before its transaction, pins the control/connection,
and retains planner source/account/link locks through page and checkpoint commit.
Family and settings reads pin the effective processing configuration. Contended
family/account locks reject instead of waiting in a reversed lock order.

The signed page retains its original checkpoint UUID, batch UUID, sequence,
preceding digest, input/output continuations, complete plan and selected account
transaction authority. Raw observations preserve section/index/ordinal ordering,
including duplicate IDs, pending exclusions, removals, malformed rows and unlinked
accounts. Canonical decimals, dates and key types use `MigrationValue` inside the
encrypted JSON document so persistence cannot silently turn them into strings.
The existing explicit identity-signing keyring signs this distinct versioned
document; older verification keys must remain available for retained evidence.

The original copy context includes the item checksum and its retained deployment
binding, credential revision, region/environment, pending preference and effective
timezone. Account rows bind the original mapping, checksum, financial account and
link revision. A missing selected authority is retained explicitly. The journal
does not select a source, infer that an Entry exists, or classify a cached
modification as financially applied. Changing authority between pages of the same
account rejects further capture rather than creating an inconsistent journal.

Each signed document is limited to 40 MiB; the source archive retains its existing
32 MiB limit and each planner page contains at most 500 physical observations.
Checkpoint state is limited to 256 KiB. Stored byte preflights and materialization
predicates bound reads. Diagnostics and object inspection omit cursor/transaction
contents. Neither reader nor publisher performs HTTP.

## Recovery and verification

Page and progress publication share one transaction. Failure before the
checkpoint commit leaves neither half committed. A fresh instance resumes the
original child checkpoint after a successful commit. Even an empty connection
records a signed terminal page, making lost-checkpoint evidence detectable.
Missing/replaced checkpoints, sequence holes, unrelated batches and changed copy
context fail instead of starting another journal. Ordinary copier restart or
return to legacy ownership cannot discard journal evidence.

After capture, verification enumerates again from the first source account and
compares every signed page, continuation, authority, chain digest and observation/
blocker count. Only this full sweep reaches `recorded`. A repeated terminal call
reports that earlier sweep; it does not claim a fresh examination of every page.
`restart_verification!` repeats the comparison without replacing original pages.
Later monetary edits are not journal failures: the journal retains observations
and ownership context, not an assertion that ledger values equal the caches.

`MigrationPreparation` has a separate `journal_cached_changes` phase after its
copy, identity and integrated-input verification. Its receipt retains the exact
child checkpoint/pages and verification-run identity. A child commit followed by
a parent-save failure resumes that same child; it does not create duplicate
evidence. Parent reverification repeats the journal sweep. Restarting parent
verification during an unfinished capture is rejected until capture finishes.
The changed Plaid input contract rejects older preparation records that do not
include this requirement; they require explicit reconciliation.

Journal progress is separate from installed-input counts. A batch marked
`applied` means its journal page committed. Its origin remains `migration`, mode
`unknown`, `complete` false and coverage empty. The checkpoint's provider cursor
and `covered_through` remain nil. No `SourceRecord`, `EntrySource`, Entry,
Transaction, balance or live transaction checkpoint is published by this command.

## Remaining cursor handoff

`recorded` can include blockers and unresolved upsert/removal observations. Every
plan retains `cursor_accepted: false`. The preferred handoff preserves the existing
ledger baseline and obtains a fresh authoritative initial transaction generation,
without seeding the copied cursor. Cache identity alone cannot establish that a
cached amount is newer than the current Entry or authorize deletion. Protected
rows must not pass through an importer merely to classify journal observations:
even a protected import can legitimately advance a pending identity.

The identity planner now permits an unambiguous, explicitly pending Transaction to
retain only its current pending ID when a cached booked row names it. Preparation
can journal that still-unapplied settlement without changing financial values,
creating the booked identity or accepting the cursor. A fresh booked observation
can then promote the proven UUID through the existing protected writer. Ambiguous
aliases and conflicting ownership remain blockers. This path has new unrun tests.

Legacy caches do not retain generation/start-cursor evidence or all account-less
removals. Journaling those caches cannot recover missing historical changes.
Rows missing from fresh upstream history must remain in the ledger: a bounded
initial history response does not authorize absence deletion or prove that every
cached change was resolved. Cache-only modifications/removals and inaccessible
history still require explicit reconciliation. Upstream reconciliation, full lifecycle drain, coordinated cursor/ownership
activation and runtime verification remain required. This journal supplies the
durable observation inventory for that work, not a substitute for it.

The focused suite covers typed signed evidence, duplicate ordering, pending and
unlinked observations, empty/incomplete caches, rollback, child/parent commit
recovery, checkpoint loss, tampering, source/configuration/policy drift, preserved
financial rows and actual preparation/reverification. All tests remain unrun.
