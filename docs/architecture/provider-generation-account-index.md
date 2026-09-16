# Original generation account ownership

Status: implemented groundwork; migration and behavioral tests are unrun. No
provider has been activated by this change. This index supplies historical owner
discovery; it does not authorize disconnect, financial deletion or source changes.

## Why current links are insufficient

A connection-wide transaction or activity generation captures its account routing
map before the first network request. Until fanout, it may have no account batch,
SourceRecord or financial evidence link. If a financial link subsequently moves or
disappears, the generation's encrypted `context_snapshot.accounts` can be the only
remaining reference to its original financial account. Fetching and abandoned
generations matter just as much as completed generations for this inventory.

`ProviderSyncGeneration.account_ids` is an indexed, immutable projection of that
original map. It includes every nonnil financial account UUID, including accounts
whose publication disposition was `retained`. It does not filter by today's links,
policy, visibility or generation status. Historical account UUIDs have no live
Account foreign key, so deletion cannot silently erase the reference.

- `NULL` means the original capture has not been indexed. It is unresolved.
- `[]` means the original capture was validated and contains no financial account
  bindings, including a capture of explicitly unlinked external accounts.
- A populated array is sorted and distinct; a GIN index supports family-scoped
  reverse lookup without decrypting every generation in that family.

`TransactionSync` derives the array from the same map it stores before HTTP.
Transactions and investment activities use this common creation path. PostgreSQL
guards prevent changes to original capture fields and to an established array;
the only completion transition is `NULL` to a projected array. Existing rows are
left unresolved by the schema migration instead of guessing from current links.

## Verification and historical backfill

[`GenerationAccountIndex`](../../app/models/provider/account_data/generation_account_index.rb)
provides four operations:

| Operation | Meaning |
| --- | --- |
| `capture_ids(context_snapshot:, stream:)` | Validate the original versioned map and derive its financial UUIDs. |
| `for_account(account)` | Find indexed generations by the account's family and historical UUID. |
| `verify!(generation:)` | Bounded fresh read; compare the projection with the original encrypted capture. |
| `assert_complete_for!(family_id:)` | Refuse a family inventory while any generation has an unknown projection. |

Missing/malformed maps, invalid binding identities and inconsistent resource or
link fields fail explicitly. A historical account need not still exist. Neither
verification nor backfill reconstructs missing evidence from today's account links.

The explicit `provider_data:index_generation_accounts` task accepts `FAMILY_ID`,
optional `AFTER_ID`, and `LIMIT` (default 25, maximum 100). Its bounded keyset page
indexes each unknown generation under its own row lock and transaction, preserving
the encrypted original, timestamps, cursors and status. An error stops that page;
earlier successful rows remain committed and retries skip completed projections.
The helper refuses an outer transaction, which would defeat that commit behavior.
No migration or backfill task has been run in this workspace.

Stored ciphertext is capped before it is loaded; decoded context also has byte,
node, depth and account-count limits. These are not a hard allocation limit for
historical compressed ciphertext: Rails decrypts/decompresses/deserializes it
before the decoded checks run. New captures are checked before encryption.
Historical decompression memory use still needs runtime acceptance.

A cursor describes traversal progress, not inventory completeness. The task checks
the whole family's unknown rows at the end, including rows before a supplied
cursor. A caller preparing a destructive command must do the same under its
complete ownership admission; concurrent new owners cannot be ignored.

PostgreSQL cannot decrypt the application-encrypted map. Nonnull projection
coverage therefore does not prove original-map integrity: direct insertion or the
initial completion of an incorrect array must still fail `verify!`. Lifecycle
consumers must verify relevant captures and reject unexplained ownership rather
than treating this index alone as permission to mutate financial records.
Checking only reverse-lookup results cannot detect a false empty projection
introduced through callback-bypassing SQL: it would omit that generation entirely.
Discovery relies on application-validated capture/backfill. Suspected bypassed
initial projections require a full-family integrity audit before this index can
support a complete owner inventory.

## Other references still required

This is one route in a complete account/source inventory. Include current and
legacy links, all historical source-policy revisions, every retained migration
archive version, SourceRecord/EntrySource/HoldingSource evidence, batch source
bindings, Account Sync inputs and Sync lineage, and document/import ownership.
For example, an IBKR equity snapshot can capture a policy before an Account Sync
input exists; its policy reference must be inventoried even without a source record.
Missing owners or unindexed archives are unresolved, not evidence of absence.

See [retained migration ownership](provider-retained-account-index.md),
[shared lifecycle admission](provider-shared-lifecycle.md) and
[implementation status](provider-implementation-status.md).
