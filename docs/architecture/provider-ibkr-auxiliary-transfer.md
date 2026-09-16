# IBKR auxiliary transfer

The implementation is now shared by the [20-provider logo transfer](provider-logo-transfer.md).
`Ibkr::AuxiliaryCopier` remains the compatibility entrypoint with its original
formats, stream, scope, idempotency prefix and HMAC salt. Existing IBKR receipts
are not converted to the new non-IBKR format.

Status: a bounded auxiliary copier, retained preparation APIs and nineteen
behavioral tests are written. They
have not run in Rails/PostgreSQL. The copier does not activate a provider, run a
migration, modify migration-control ownership, or claim that a shadow comparison
is sufficient for cutover.

## Inventory and disposition

| Persisted data | Existing location | Disposition |
| --- | --- | --- |
| Connection credentials and root Flex metadata | `ibkr_items.query_id`, `token`, `raw_payload` | Already included in the reviewed main-row manifest and encrypted migration snapshots. |
| Holdings, trades/cash activities, cash reports and historical equity | The four `ibkr_accounts.raw_*_payload` fields | Already included in the main-row encrypted snapshots. No second financial-data copy is needed. |
| Report date and holdings/activity checkpoints | `ibkr_accounts.report_date`, `last_holdings_sync`, `last_activities_sync` | Existing typed row snapshot and encrypted `legacy_state` checkpoint. |
| Original downloaded Flex XML | No legacy persisted location | The legacy importer parses then discards the XML; `raw_payload` retains root metadata, not XML. A new original export cannot be reconstructed from those rows. Native exports use the separately captured immutable protocol. |
| Institution logo attachment | `active_storage_attachments`, with `record_type = 'IbkrItem'` and name `logo` | Preserve the original attachment UUID and capture all its columns in an encrypted manifest. Create one target attachment with a new UUID to the same existing blob. |
| Logo metadata and content | `active_storage_blobs` and its storage object | Preserve blob UUID, storage key, filename, metadata, service, checksum, size and timestamps. Archive exact bytes in encrypted chunks and verify their content before linking the target. No new blob or storage object is created. |
| Derived logo variants | Shared Active Storage variant records and their images | Retain in place under the same original blob UUID. They remain shared derived caches; this slice does not copy or purge variant objects. |
| Existing sync history | `syncs`, still owned by `IbkrItem`/financial accounts | Retain Sync UUIDs, status, timestamps, windows and parentage. `Family::ProviderSyncables#history_scopes` continues to include legacy and shared owners. No fabricated native Sync is created for migration evidence. |
| Financial accounts, entries, trades, balances, holdings and security records | Shared financial tables | Retain existing UUIDs. The main copier binds existing AccountProvider links; this auxiliary copier does not mutate financial records. |

There are no IBKR-specific auxiliary SQL tables beyond `ibkr_items` and
`ibkr_accounts`. Monobank has the same item/account topology and an item logo:
its statement cache and history checkpoints reside on `monobank_accounts` and
are covered by its existing row manifest. Its logo needs a separately reviewed
auxiliary adapter; this implementation deliberately accepts IBKR controls only.

## Bounded copy and verification

After the ordinary copier has created a disabled mapped connection:

```ruby
copier = Provider::AccountData::Ibkr::AuxiliaryCopier.new(
  control: ibkr_migration_control, chunks_per_run: 4, chunk_bytes: 128 * 1024
)
checkpoint = copier.run
# Repeat bounded calls until checkpoint.state["phase"] == "complete".
```

Each call enters the same-item exclusive `LegacyWriterFence`. It supports reentry
when the quiesced coordinator already holds that exclusive fence. Storage range
reads must occur outside database transactions; the copier rejects a transaction
wrapped caller. Short publication transactions lock migration control, disabled
connection and the auxiliary checkpoint, then pin source attachment metadata.
The control's state, lease, high-water mark and audit results are never changed.
`quiescing` is accepted for final-copy coordination, alongside pre-cutover shadow
copy states. Active/retired ownership and an enabled target are rejected.

Progress lives in a separate encrypted `ProviderSyncCheckpoint` with stream
`legacy_ibkr_auxiliary` and scope `IbkrItem:<UUID>:logo`. Its manifest retains exact
typed attachment/blob columns and an HMAC of their complete values. A resumed
worker uses the stored chunk size and indexes. Successful chunks and progress
commit together; retries do not duplicate previously captured chunks.

Migration-origin `IngestionBatch` records hold encrypted Base64 chunks. They have
no provider Sync, account or manufactured ingestion coverage. Their provenance
identifies the source manifest, fixed chunk layout and sequence. Limits are 32 MiB
per original logo, 256 KiB of manifest metadata, 1 KiB–1 MiB per chunk and at most
eight storage ranges per call. Completion verifies the whole bounded archive
against the original Active Storage MD5 checksum and records a SHA-256 digest.
The MD5 comparison implements Active Storage's existing checksum contract; the
archive additionally uses SHA-256 and authenticated encrypted storage.

The verification pass reads each original range again and compares it byte for
byte with the encrypted archive. Only then does the copier create a target
attachment to the existing blob. It inserts that join directly to avoid analysis,
upload, source-touch or purge callbacks. An identical existing target attachment
is reused; a different target logo causes a conflict and remains untouched.
An absent logo is recorded explicitly and completes without any blob reads.

Source attachment/metadata drift, changed storage bytes, missing chunks, checksum
failure, unknown attachment schema or oversized data stop the operation. Prior
evidence and its progress remain available for review. The copier does not silently
replace a changed source revision or overwrite an independently supplied target
logo. Reconciliation/restart of a changed capture needs an explicit operator plan.

## Recovery and final-copy handoff

After authorizing the control's family, `copier.each_archived_chunk` yields exact
bytes for inspection or a separately authorized restoration. It verifies every
chunk and the aggregate checksum before yielding any bytes. This read API never
creates a storage object or changes an attachment.

The original shadow `run` and `restart_verification!` APIs remain available for
their original receipts. They do not turn a shadow archive into evidence for a
particular verified main copy. Lost checkpoints with surviving auxiliary chunks
are rejected instead of recreating their progress.

For a fresh quiesced preparation, use the connection-scoped retained API after
the main row copy is verified and before financial identity publication:

```ruby
receipt = copier.run_retained(family: authorized_family)
# Repeat with a fresh worker and the same context until receipt.complete?.
receipt = copier.run_retained(
  family: authorized_family, expected_context: receipt.context
)
```

Each immutable receipt includes `phase`, `checkpoint_id`, `context`,
`copied_chunks` and `verified_chunks`. Its context contains format
`ibkr-retained-auxiliary/v1`, the main retained-copy context under `copy` (without
its account-page size), the original auxiliary checkpoint UUID, source manifest
digest, chunk size/count and `requires_cutover_reverification: true`. The main
context pins copy-run UUID, item checksum/mapping, family, source/connection,
credential revision, region/environment and account count. Every short guarded
step rechecks that original main copy, including its exact source projections.
Native epochs, leases, executions and enabled connections refuse auxiliary work.

New receipts persist that context before reading bytes. They retain the original
chunk layout across worker reconstruction and record every target attachment
column at completion. Financial identity progress prevents starting or completing
an unfinished auxiliary capture. Completed retained receipts can be read and
reverified after identities exist. Old receipts without the copy binding require
explicit reconciliation: this slice does not implement even a pre-identity
adoption protocol, replace their chunks, or infer the original copy run. The
shadow mutation APIs reject retained-bound receipts so they cannot reset them.

Final verification preserves the original completed checkpoint:

```ruby
page = copier.verify_retained_page(family: authorized_family, limit: 4)
# Retain every page; pass next_cursor unchanged to a fresh worker.
page = copier.verify_retained_page(
  family: authorized_family, cursor: page.next_cursor, limit: 4
)
```

`VerificationPage` contains immutable `context`, `rows`, `next_cursor` and
`complete`. Each row identifies a chunk index, byte count and SHA-256; no content
bytes are returned. The verification context extends the receipt context with
the original aggregate SHA-256, typed target attachment tuple and fixed page
limit. Each call compares at most one to eight current storage ranges with their
original encrypted chunks. Storage reads remain outside DB transactions; context,
source metadata, target attachment and checkpoint state are rechecked after each
read. The terminal page additionally scans the original bounded encrypted archive
and its exact batch inventory, verifying both aggregate checksums. That terminal
DB work can read the full 32 MiB archive; the page limit bounds remote range reads,
not the final database checksum pass. State is limited to 1 MiB, and metadata and
chunk materialization repeat their stored-byte predicates.

Missing chunks, changed checkpoint/copy run, changed page size, target metadata or
source bytes reject the page without resetting progress or modifying financial
identity proof. An absent logo has an explicit zero-chunk receipt and an empty
terminal page. The coordinator must retain all returned pages and reconcile their
contiguous indexes/counts; `complete` only ends enumeration. The checkpoint still
reports `requires_final_reverification: true` and
`source_quiesced_across_calls: false`: individual calls do not prove that writers,
attachment lifecycle operations or storage changes remained quiesced between
calls. The [preparation coordinator](provider-migration-preparation.md) now retains
this connection-scoped receipt before identities and verifies every final page
after its fresh copy/identity sweeps. It also covers connections with no accounts.
Losing the parent while any auxiliary checkpoint or chunks survive requires
explicit recovery; the coordinator will not adopt a standalone receipt into a new
run. Final all-source admission and activation remain separate work.

Acceptance still requires running the copy/resume/integrity/ownership tests with
real commits and the configured Active Storage service, validating its range-read
and checksum behavior, testing quiesced final-copy coordination and separately
auditing logo/variant deletion callbacks before retiring compatibility records.
No source attachment or blob has been purged, and no provider has been activated.
