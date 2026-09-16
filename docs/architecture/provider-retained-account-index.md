# Retained financial account ownership

Status: implemented with authored, unrun behavioral tests. The additive migration
has not been applied here. No copied data has been backfilled, deleted or activated.

## Why live links are insufficient

An account can lose its AccountProvider link while an encrypted migration archive
still records its original UUID. Copying again can also retain several versions
with different financial bindings. A lifecycle command that inspects only today's
links or a mapping's latest checksum can miss affected source owners.

[`ProviderMigrationAccountBinding`](../../app/models/provider_migration_account_binding.rb)
is a reverse index for each retained account archive version. A receipt identifies
its mapping, source HMAC checksum, first batch and exact chunk count, plus the
captured linked/unlinked state. Linked receipts retain the original financial
Account and AccountProvider UUIDs. These historical UUIDs have no live foreign keys:
removing a join or financial row must not erase the index of its former ownership.
They are evidence, not permission to publish or proof of current source authority.

The database constrains receipt tenant ownership, the exact archive header, shape,
uniqueness and immutable updates. The first-batch FK prevents casually removing the
archive root while its index survives. The insertion guard deliberately compares
the receipt's checksum, not the mapping's current checksum. Multiple old versions
can legitimately coexist. Rollback of the schema migration refuses existing
receipts rather than silently dropping retained ownership information.

## Capture and verification

[`RetainedAccountIndex`](../../app/models/provider/account_data/retained_account_index.rb)
creates receipts only after reconstructing the encrypted chunks under the existing
archive HMAC check. It verifies the account source, family, item and external-account
identities, then validates the captured financial/link binding. It never reconstructs
historical identity from the current AccountProvider row. Missing account-binding
metadata, invalid chunks, changed payloads or inconsistent family/source identities
cannot produce a successful receipt.

The copier captures the receipt in the same transaction as the account's complete
archive. Retries verify existing receipts and preserve their UUIDs. The normal and
retained account-verification paths independently check the current receipt against
its archive. Copy finalization, retained verification and preparation also require
coverage of every retained account archive version, including superseded ones.

`snapshot_for` accepts an explicit historical `source_checksum` while retaining
scope and HMAC verification. The index caps reads at 1,024 chunks and 32 MiB of
decoded archive data, with a stored-size preflight before decrypting payloads.
It locks the migration control before the external account and mapping, then the
chunk rows, refusing contention with `NOWAIT`. The external-account FK lock also
excludes new chunks during reconstruction. This operation performs no HTTP and
does not change copy progress, financial records, checkpoints or writer epochs.

`for_account(account)` returns family-scoped historical receipts. An empty result
does not establish that the account has no retained dependencies. A lifecycle
caller must first establish complete archive coverage under its own admission,
verify relevant archives and independently inventory native/source evidence.

`unindexed_chunks(family_id:)` checks every account archive chunk against exact
receipt membership. Only a strictly recognized item header is excluded; malformed
chunks cannot disappear by losing their external-account FK and account scope.
Orphan chunks, extra sequences, unknown prefixes and missing roots
remain unresolved; they are not silently classified as unlinked. Receipt coverage
does not replace HMAC verification when the archived contents are used.

## Existing copies and explicit backfill

Existing archive versions need an index before preparation can claim complete
retained coverage. Use `bin/rails provider_data:index_retained_accounts` with
`FAMILY_ID` set to the intended family. Optional `LIMIT` is 1–100, default 25;
`AFTER_ID` resumes from the reported root UUID. No task runs automatically.

The task enumerates all first chunks in UUID order, including versions older than
the current mapping. Each successful archive commits independently, so retrying a
page preserves completed receipts. It reads only scalar root headers before the
bounded archive verifier. It prints the next cursor and whether any account chunks
remain unindexed. A final enumeration page with unresolved chunks exits with an
error: finishing root enumeration does not prove complete archive coverage.

Missing bindings in older formats require explicit reconciliation; neither
recopying today's link nor deleting an old version repairs that historical proof.
Concurrent new copies can precede a pagination cursor, so a lifecycle operation
must repeat the coverage check under its complete source admission before relying
on the inventory.

## Remaining lifecycle work

This index closes the retained-copy discovery gap. It does not implement Account
destruction or native disconnect. Those commands still need the complete financial
effect graph, current/native source admission, transaction/holding evidence
retirement, policy history, statement handling and failure recovery described in
[shared lifecycle admission](provider-shared-lifecycle.md). Provider batches,
SourceRecords, Account sync inputs and document evidence are separate dependencies;
they must not be inferred from migration receipts.

The [index tests](../../test/models/provider/account_data/retained_account_index_test.rb)
use real copied archives for versioning, backfill, corruption, bounds and coverage.
The [receipt tests](../../test/models/provider_migration_account_binding_test.rb)
cover model and SQL constraints. Runtime concurrency, all-provider copy parity,
migrations and full repository checks remain unrun because Ruby/Bundler are unavailable.
