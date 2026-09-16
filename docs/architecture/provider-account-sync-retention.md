# Retained account calculation ownership

Status: migration, model integration and regression tests are written but unrun.
No schema migration, account retirement or provider cutover has been performed.
This extends [fresh calculation admission](provider-account-sync-admission.md)
and [retained financial identities](provider-retained-financial-account.md).

## Preserve executions without retaining every empty job forever

The existing `syncs` row remains the execution identity. There is no replacement
execution table or copied job UUID. `account_family_id` records an Account Sync's
family independently of its mutable or missing polymorphic receiver. New jobs
capture an eligible live owner in both Rails and PostgreSQL. The original Account
UUID, owner type and captured family cannot subsequently be reassigned.

The migration compares live Account, immutable input and existing retained-identity
proofs before backfilling. Conflicting proofs abort the migration transaction.
An orphan without any of these proofs stays unknown; its parent or provider does
not establish which family originally owned the financial account. Workers,
retry and publication cannot adopt a job with unknown ownership. Unknown jobs
that contain preparation or materialization evidence also require explicit
disposition before deletion; missing ownership is not permission to erase them.

Every ordinary calculation now has an input seal, including calculations with no
provider inputs. An empty seal alone is job metadata, not permanent financial
evidence. Ordinary live-history cleanup and legacy account deletion remain
available. Actual inputs, preparation, selected input pointers or a materialization
marker make ordinary Account destruction refuse before dependent callbacks run.
This also protects evidence after an independently removed source policy.

## Retired evidence and database boundaries

Account input ownership moves from the live `accounts` foreign key to
`account_ingestion_identities`, preserving account/family UUIDs. The execution FK
also checks its captured family. Existing input ciphertext, payload digests,
source-batch/provider-Sync pointers and job IDs are not rewritten by that transfer.

Inputs and preparation remain immutable and tied to their original Sync. After
retirement, deleting that Account Sync is refused, including when an ancestor's
Rails dependency cascade reaches it. The transaction rolls earlier dependency
deletions back. The selected input pointer also rejects update or deletion after
retirement. Previously sealed windows, parent/predecessor IDs, input digests and
materialization markers keep their existing guards.

Creating inputs, preparation or a selection requires a fresh eligible live Account
and a matching non-retired identity under locks. Persisted evidence validation is
separate from this creation gate: retained history can still be inspected after
its live account disappears. `SyncInput#resolve!` first checks the live owner and
raises the typed unavailable-owner error before resolving financial inputs.

The owning Sync's input/preparation cascade remains available for explicit live
history cleanup; this is not a general purge API. Once the identity is retired,
ordinary deletion cannot use that cascade. The family FK permits a future full
family erasure to remove Account Syncs after deleting their Family, consistent
with the identity's family-erasure boundary. Other evidence and selected-source
FKs still require coordinated disposition. A native full-family erasure command
is not implemented by this migration.

## History access and current work are distinct

Internal family history uses the captured family, including retired or missing
accounts. User-facing history additionally requires the live account to remain in
that user's accessible-account scope and in the same family. No admin bypass is
added, and old account names, owners or shares are not reconstructed from payloads.
Retired user-facing history needs a separate retained permission model.

Account association and aggregate history queries include the family key.
Changing a live account's family cannot expose an earlier family's jobs through
that account. Worker admission, retry, sealing and publication compare the original
binding; current-work indicators exclude unavailable accounts. The stale-job sweep
can terminalize missing/retired owners without validating a nonexistent live
receiver or dispatching completion side effects.

Financial reset keeps the Family alive, so it explicitly refuses retired identities
before starting financial deletion. The database guards also protect retained
Syncs from bulk deletion. This preflight does not complete the broader native reset,
credential revocation or lifecycle admission protocol.

## Verification and remaining work

Behavioral coverage is written for ownership capture, private-account access,
family changes, worker/cleaner admission, retained evidence inspection, refused
raw and ancestor deletion, live cleanup, reset refusal and ordinary empty jobs.
The new migration has dedicated transfer/rollback acceptance coverage. All of
these tests require execution in the project's Ruby/PostgreSQL environment.

The admitted Account retirement command still needs source-owner admission,
the calculation session lock, financial effects handling, statement disposition,
source detachment, scheduling and recovery. Existing public deletion deliberately
refuses retained financial evidence until that command can perform the complete
operation. See [implementation status](provider-implementation-status.md) for the
remaining provider migration gates.
