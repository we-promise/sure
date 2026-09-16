# Retained financial account identity

Status: schema, capture and evidence safeguards written; migration and behavioral
tests unrun. This is a prerequisite for native account retirement, not a completed
deletion command or provider cutover.

`SourceRecord.account_id` is an original financial identity. Published observations,
EntrySource/HoldingSource mappings and signed bootstrap payloads must retain that
UUID after a live Account is removed. Clearing it would turn a published observation
into an unbound one; replacing it would invalidate provenance.

[`Account::IngestionIdentity`](../../app/models/account/ingestion_identity.rb) gives
that UUID an independent owner. Its primary key equals the original Account UUID,
and its family is immutable. `live_account_id` points to that same Account while it
exists. Retirement clears only this live pointer and records `retired_at`; it cannot
be reversed. No balances, transaction descriptions or credentials are copied into
the identity table.

The SourceRecord composite FK now targets this identity and family rather than the
live Account. Existing EntrySource/HoldingSource composite ownership and immutable
bootstrap references continue using the original UUID unchanged. Their `account`
association is an optional live lookup; `account_identity` describes the durable
owner. A retired identity is distinct from a SourceRecord that was never bound.

## Capture and migration

Normal source selection or first publication captures the identity before saving
a policy or bound SourceRecord.
Previously unbound observations acquire it when an authorized writer first binds
them. Capture locks Account then identity, using nonblocking locks; repeat capture
returns the existing live identity and never reactivates a retired one. Existing
publication and signed bootstrap verification retain their authorization checks.

The observation migration copies distinct bound SourceRecord account/family UUIDs from their
existing FK-validated Accounts and replaces the ownership FK transactionally. It
does not create identities from guessed or orphaned historical references. Unbound
observations remain unbound. The [policy retention migration](provider-source-policy-retention.md)
also transfers FK-validated existing policy ownership to these identities.
No application migration or live backfill has run here.

Database guards preserve a bound observation's account UUID even through callback-
bypassing updates. Evidence mappings preserve original account, family, source and
financial UUIDs; a live financial pointer must match its retained UUID. New source
observations and mappings cannot publish to a retired identity. Existing retired
observations and mappings can no longer change their content.

## Retirement boundary

The schema permits a one-way retirement only after all financial evidence is
inactive with its live Entry/Holding pointer cleared. A deferred check requires
removal of the live Account in the same transaction. Original financial UUIDs and
bootstrap evidence remain intact. Account INSERT and primary-key UPDATE cannot
reuse a retained UUID. A retired identity cannot be deleted while its family
exists; a full-family purge still has to dispose of referenced evidence explicitly.

The model does not expose a public retirement method. The existing Account destroy
path first locks the Account, then refuses a retained identity with observations or policies,
or actual calculation inputs, preparation, selection or materialization evidence,
before dependent callbacks run. The former `source_records` destruction cascade
is now restrictive. An unused live identity can be removed with its Account.
Lock contention aborts this preliminary check after rolling back its savepoint;
it does not invoke the existing exception-based status recovery.

Scheduling performs its retained-evidence check after the status update acquires
the Account lock and before enqueue. Refusal rolls back `pending_deletion` instead
of leaving a hidden account behind a job that cannot delete it. First identity
capture and the source-observation guard reject accounts already pending deletion,
so first publication cannot enter after successful scheduling. This does not repair
old queued jobs or replace complete source-owner admission for deletion.

These safeguards do not make account deletion complete. The future admitted
command must use retained source-policy ownership, preserve Account Sync inputs and original
batches, cover legacy and native source owners, preserve statement provenance and
handle dependent financial edits. It must recheck permissions, original evidence
and the full graph under locks, then retire identity and delete the live Account
atomically. Scheduling, failure recovery, reset/import-revert paths and native
connection behavior after retirement remain integration requirements.

Read-only source discovery now includes identity row versions. It still refuses
retired peers requiring lifecycle disposition; it does not infer a live account
from a retained UUID. Runtime collectors remain live-account-only. Reassigning a
statement or reconnecting a source must not rebind old observations to a new account.

[Account calculation admission](provider-account-sync-admission.md) now checks
live ownership before queueing, worker recovery, publication and post-sync work.
Unavailable jobs do not fabricate seals or replay completion effects.
[Calculation ownership retention](provider-account-sync-retention.md) now captures
the original family, transfers input ownership to the identity and guards retired
executions and selected inputs against deletion. These migrations and tests are
unrun; the complete retirement command remains an integration requirement.

See [source discovery](provider-account-source-inventory.md),
[shared lifecycle](provider-shared-lifecycle.md),
[multiple-source ingestion](multi-source-ingestion.md) and
[implementation status](provider-implementation-status.md).
