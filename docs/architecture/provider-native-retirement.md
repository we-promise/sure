# Physical retirement of provider compatibility rows

`Provider::AccountData::MigrationRetirement` is the explicit command after native cutover. It removes approved legacy item/account rows while preserving the shared connection, external accounts, financial accounts, entries, holdings, AccountProvider UUIDs and legacy tuples, source policies, source evidence, migration mappings, authenticated archives, and original Sync history.

```ruby
Provider::AccountData::MigrationRetirement.new(
  provider_key: "up", legacy_item_id: original_item_id, family: authorized_family
).call
```

The result contains `control_id`, `connection_id`, and `replayed`. The command neither queues a sync nor calls a provider. It must start outside a database transaction so the exclusive legacy writer permit can be acquired first. It remains subject to the production adapter's `native_ready?` gate. Writing this command does not activate Mercury, Brex, or any other adapter.

The initial reviewed dispositions are Up, Mercury, and Brex. Their source rows have no financial Account direct foreign keys or independent deferred request protocols to dispose of. Their sole declared attachment is the item logo. Every other provider is refused before mutation; a migration manifest alone does not authorize deletion. See the [23-provider retirement inventory](provider-retirement-inventory.md) for concrete remaining child-request, direct-link and auxiliary work.

## First retirement

The caller needs the original native cutover and completed preparation, an active control and good native connection, and no pending deletion, lease, unfinished generation or incomplete legacy/native/affected Account Sync. Existing credential claims must be settled. The command requires the exact bounded legacy child/mapping inventory, same-family native targets and unambiguous current financial links. It refuses undeclared account attachments or item attachment names.

The exclusive legacy permit spans an auxiliary storage verification followed by one database transaction. Logo verification checks the archived bytes before the transaction; the final database-only step pins the same original archive, attachment and blob metadata. Only the original legacy attachment is deleted. The native attachment, blob and storage object remain; no purge or provider disconnect callback runs.

The final transaction locks current owners with `NOWAIT`, checks stored payload bounds before hydrating source rows, and compares every current legacy attribute with its authenticated original archive. Changed legacy credentials, cache data or source metadata require reconciliation. Current financial links are checked separately: legitimate native unlink does not rewrite the original archive or invent a replacement financial owner.

`RetiredOwner` witnesses are captured while source rows still exist. Only then does the command delete the exact legacy account/item rows without callbacks and atomically set the control to `retired` with a signed durable `native_retirement` receipt. It verifies the absent-owner resolvers before commit. A failure rolls back the deletions, attachment removal, newly captured witnesses and receipt together.

## Retry and limits

A completed retry starts from the retained control, because there is no live item from which to acquire a legacy permit. It verifies the receipt's retained identity-signing key, original cutover, exact mapping/witness inventory, original source absence, current shared ownership, authenticated archives and retained logo target. It does not repeat deletion or storage reads. Later native work does not invalidate a completed receipt; row contention can still ask the caller to retry.

The audit JSON is not a database-immutable column. The receipt is signed and replay detects modification; the command never treats an unsigned replacement as proof. Retained signing keys and original cutover Sync/history remain required. Loss of an archive, mapping, original cutover Sync or auxiliary proof requires explicit repair instead of inferred success.

The command bounds original accounts at 100, aggregate original typed source archives at 32 MiB, and its signed receipt at 1 MiB. Stored encrypted source bytes have a separate bound. Historical compressed Rails documents still allocate during decoding; the stored bound is not a promise of an independent decompression allocation limit.

This command does not delete a financial Account, purge a family, revoke remote credentials, import historical data, change checkpoints, or assert history coverage. It is physical compatibility retirement after an already verified native cutover. Behavioral tests for all three admitted providers and rollback/refusal/replay cases are authored but have not been run in the current environment.
