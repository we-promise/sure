# Wise interbalance transfers

`Wise::InterbalanceTransfers` now runs at the end of the shared Syncer's account
loop, before ordinary stream errors are aggregated. It creates a confirmed
`Transfer` only from two committed native Wise postings for the same completed
`INTERBALANCE` / `BALANCE_TRANSACTION` event. Wise remains disabled for native
activation. The implementation and behavioral tests are written but unrun in
this environment.

The legacy linker searches for `wise_interbalance_<resource-id>_inflow` and
`_outflow` entries and takes the first matching STANDARD counterpart. Those
suffixes identify the JAR and STANDARD representations, respectively; they do
not always identify the economic direction. Native normalization preserves
these IDs. Finalization uses the actual amount signs to choose the transfer's
inflow and outflow, including withdrawals from a JAR.

New activity metadata retains the profile, event and resource IDs, account side,
upstream balance ID, explicit currency, JAR name and a fingerprint of the exact
event fields. The finalizer rereads bounded encrypted original pages, verifies
their captured request grant and account-request proof, and recomputes this
metadata from the retained raw activity. Matching names, dates or amounts alone
cannot authorize a transfer. The two representations must describe the same
event with equal and opposite amounts, the same currency and date.

The [statement barrier](provider-wise-statement-barrier.md) supplies complete,
unchanged profile discovery and holds the original account/link/policy admission
while finalization locks observations, posting mappings, entries and
transactions. Exactly one active STANDARD balance and one matching active JAR
must exist in that inventory, including unlinked balances when deciding whether
routing is ambiguous. Both postings must be in distinct, linked financial
accounts in the same family, with Wise still selected for transactions and the
original batch bindings unchanged. Secondary-source observations cannot claim
another source's postings.

At least one current `SourceRecord` must point to an applied batch from the
logical Sync being finalized. The other may retain an earlier Sync's applied
batch if its original grant, request inputs and current source binding still
verify. This supports a missing counterpart arriving after an independent
account failure without requiring the older activity to appear again. A
replaced credential/configuration or binding can make that old proof stale;
finalization then fails closed and requires review or a newly proved observation.
It does not infer authorization from the surviving financial entry.

Only the `Transfer` join is created. Entry and Transaction financial attributes,
names, notes, categories, kinds and IDs remain unchanged. Existing exact pending
or confirmed transfers are left as they are, matching the legacy linker's
already-joined disposition. Rejected pairs, competing transfers, fee-associated
postings, splits, reconciled entries, protected entries and changed economics
are skipped. Missing posting pointers or ambiguous/incomplete activity proof
also produce sanitized review counts, without exposing the raw event. Invalid
authorization or source identity is an error rather than a skipped ownership
check. All newly created joins roll back if finalization fails.

An account `DeferredPage` postpones pair finalization until continuation has
finished the original page sequence. This preserves the existing same-Sync job
schedule; historical counterpart review cannot replace that retry reason.
Ordinary errors still use the existing job failure behavior. Retained evidence
supports direct same-Sync replay, not automatic restart of a terminal failed job.

Work is bounded to 2,000 candidate observations/activity rows, 8 MiB per original
stored or decoded batch and 32 MiB cumulative stored plus decoded reads. Stored
size is checked before payload materialization. Finalization performs no HTTP,
does not change coverage/checkpoints and never invokes heuristic transfer
matching.

Tests use the real Registry, Syncer, LedgerWriter, SourceRecord and EntrySource
paths with an in-memory provider transport. They cover both directions,
idempotence, an older counterpart, actual job continuation, ambiguous unlinked
inventory, conflicting IDs/facts, completion status, protected/reconciled/edited
postings, pending/rejected/competing/fee decisions, secondary-source authority,
missing proof, callback rollback and bounds. Transfer callbacks are observed to
ensure that creating the join leaves both financial postings unchanged.

Ambiguous multi-STANDARD or duplicate-name JAR profiles require explicit routing
disposition; no new topology identifier is invented. Older native pages without
this event proof, unapplied legacy caches, cross-currency movements, incomplete
coverage acceptance, lifecycle/cutover and promotion reset remain separate
migration requirements. No legacy processor, migration or activation is invoked.
