# Up migration cutover

Status: implementation and behavioral tests are written but have not run. No
connection has been activated in this workspace. This is the first explicit
activation command; it does not make the other 22 provider ports ready or finish
the remaining shared setup, credential editing and connection deletion workflows.
The command now also has a [Mercury handoff contract](provider-mercury-cutover.md),
which remains blocked by Mercury's native-readiness gate.

## Ownership handoff

For `provider_key: "up"`, `Provider::AccountData::MigrationCutover` accepts one
exact family and legacy Up item. It requires the original `MigrationPreparation` run at
`awaiting_acceptance`, including retained copy, financial identity and auxiliary
receipts. It rejects a shadow copy, an unfinished preparation, an unsupported provider,
changed source ownership, scheduled deletion or unresolved legacy Syncs.

The command holds the actual exclusive legacy item permit for the entire handoff.
It rereads every archived logo chunk from storage before the final database
transaction, then locks and rechecks the source/target attachment metadata and
archive chunks inside that transaction. It locks the shared connection, financial
accounts, existing entries and their value records; repeats the complete copy
and identity verification sweeps; and preserves the original Account,
AccountProvider, Entry and financial evidence identities.

The shared `MigrationSourceSelection` preparation step installs missing Up
transaction/balance source selections only when
the financial account has one provider link and no direct Plaid/SimpleFIN source
claim. It retains existing explicit choices.
Accounts with several links and missing selections require an explicit choice;
migration must not silently pick a winner. Selection precedes identity publication
because the evidence binds the selected policy revision.

Activation commits `active` ownership, a `good` shared connection, initial writer
epochs and one pending native Sync together. Queue dispatch happens after commit
and release of the exclusive permit. A queue outage leaves that exact Sync and a
durable cutover receipt available for retry. Repeating the command never creates
a replacement first Sync, and never switches ownership back to legacy. Native
execution may advance the connection epoch without invalidating that receipt.

The command bounds the final transaction to 100 external accounts and 10,000
financial entries. Larger inventories require a reviewed handoff strategy;
the command refuses them rather than accepting partial verification. These bounds
are pilot limits, not limits on the shared ingestion model.

## First native history

Each external account retains its own initial history date, installed atomically
in declared adapter metadata. An explicit account date takes precedence over the
connection date. Otherwise, a nonempty cache uses the last completed legacy Sync
minus seven days when available, with the 90-day default for other cases; validated
cached dates may widen that account's unconfigured window. A sibling's earlier
history never widens another account's configured window.

The first native Sync has no connection-wide date override. The adapter's pure
history policy reads the declared account metadata, which request admission pins
alongside the selected window. Existing explicit dates and later completed
checkpoints take precedence. No legacy sync timestamp becomes a native
`covered_through` checkpoint.
Fetching the dates again cannot guarantee that upstream still returns every cached
row. Linked cached observations therefore need exact retained financial identity
or an explicit signed retired-alias disposition. Current observations must also
agree with the financial baseline in their original bootstrap proof; finding an
existing transaction ID alone does not establish that its latest cached revision
was processed. Later user edits are preserved. An override predating bootstrap
that cannot be distinguished from an unapplied cached revision requires review.

Malformed rows, duplicate cached identities, missing provenance, unsupported
withdrawn/tombstoned dispositions and nonempty unlinked caches block activation.
Empty unlinked accounts remain discovery-only. This gate reads bounded original
archives and financial proof; it neither publishes cached data nor claims upstream
coverage. Retained-cache publication and resolution of these blockers remain work
before a general rollout.

## Compatibility and operation

The existing Up manual-sync route now uses `UpItem::SyncRequest`. It rechecks the
current administrator and family, the originally selected migration owner and
the exact connection mapping. Legacy-owned requests schedule the legacy item;
native-owned requests schedule the shared connection. Ownership changes require
a fresh request. There is no fallback that schedules both writers.

The operator entry point is `provider_data:cutover`, with `PROVIDER=up`,
`FAMILY_ID`, `LEGACY_ITEM_ID`, and the same `PAGE_SIZE` used for preparation.
It is not called automatically by copying, preparation, the generator or a job.
Do not treat the existence of this task as deployment acceptance: execute the
Rails/PostgreSQL tests and finish the remaining lifecycle workflows before rollout.

Post-native rollback cannot use the preactivation copier's `resume_legacy!`.
Once native observations have been published, rollback needs explicit reconciliation
and ownership transfer while preserving those observations and financial identities.
