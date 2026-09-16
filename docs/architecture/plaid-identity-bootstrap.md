# Plaid financial identity bootstrap

`Provider::AccountData::Plaid::IdentityBootstrapPlan` prepares a bounded, read-only review of existing financial identities after `MigrationCopier` has copied and verified a Plaid account. It does not publish source evidence, change an Entry, advance a provider cursor, create a Sync, or enable native ingestion. The separate internal [identity publisher](financial-identity-evidence.md) now consumes fresh plans under the actual legacy fence and commits evidence with its own checkpoint. These paths are written but unrun; Plaid remains gated.

## Existing identity behavior

Both current Plaid banking transactions and investment activities use `entries.external_id` with `source = 'plaid'`. The unique identity is account + source + external ID, across both Transaction and Trade entries. Plaid EU uses the same source; the connection's region selects its application credential realm.

The October 2025 backfill copied `plaid_id` only where `external_id` was null and source was null or `plaid`. Consequently an old `plaid_id` can still be the only identity, or it can differ from the current external ID. It must not be overwritten or assumed equivalent without evidence. The legacy removed-transaction processor still looks up `plaid_id`, which is another reason this migration must explicitly audit both columns.

When a posted transaction claims a pending Entry, the importer preserves its UUID, replaces its external ID, and records the old IDs in `Transaction.extra.auto_claimed_pending_ids`. Plaid's own pending link is also stored in `extra.plaid.pending_transaction_id`. Those retired aliases identify the same financial Entry, but replaying an alias must not turn the booked Entry back into a pending transaction.

Investment cash movements are Transactions in the `activities` stream. Trade implies activity; Transaction alone does not distinguish banking from investment cash. A current account archive can establish the stream through its `raw_transactions_payload` or `raw_holdings_payload.transactions`; explicit legacy `extra.plaid` also identifies a banking transaction. The latest archives are partial histories: absence never proves deletion. An otherwise unclassified cash movement is a review blocker.

The current AccountProvider constraints allow one Plaid link per financial account, shared by US/EU. The planner verifies the retained legacy provider UUID, copied ExternalAccount, family, and optional direct legacy link. It rejects competing or inconsistent links. Supporting several same-provider connections to the same financial account later would require explicit item ownership evidence; `source = 'plaid'` alone cannot select an item.

## Read-only planning

The caller supplies an authorized family and a verified external-account migration mapping. The connection must remain disabled and the control must be in `shadow` or `quiescing`. These are planning prerequisites, not proof that old writers have stopped.

The planner reconstructs the encrypted typed archive using `MigrationCopier.snapshot_for`, including checksum verification and a 32 MiB/1,024-chunk read limit. It checks the source account, parent item and upstream account identity against the mapped target before inspecting financial records. Archive rows explicitly naming another upstream account abort planning.

Each page contains at most 500 candidate Entries, ordered by UUID. Candidates are every Entry with source `plaid` or a non-null `plaid_id`; manual and other-provider rows without a Plaid identity remain outside the plan. Each accepted row captures:

- The exact Entry UUID, entryable type, current provider ID, and separately declared pending aliases.
- Original `plaid_id`, `external_id` and `source` values, without rewriting any of them.
- Typed snapshots of all Entry and entryable attributes, including amounts, dates, labels, protection flags, locks, import/reconciliation/split references and metadata, plus a deterministic checksum.
- The archive paths supporting stream/alias interpretation, and the checksum of the verified legacy account archive.

The page also captures family, connection, ExternalAccount, AccountProvider and migration mapping UUIDs, region/environment, credential revision and writer epochs. Continuations must match those values exactly. A blocked page supplies no continuation, so a caller cannot accidentally advance past an unresolved row. Collision checks include Entries outside the current page and existing native evidence, not just the rows in memory. Private typed snapshots must only be persisted to encrypted evidence, never logs or ordinary JSON metadata.

The output is immutable in memory. A fresh plan may differ while legacy sync or user edits continue. UUID ordering is a bounded enumeration mechanism, not a financial change-feed: a final quiesced sweep must catch insertions or changes behind an earlier page boundary.

If a cached booked transaction names an Entry that is still explicitly pending,
the planner now retains only that Entry's current pending ID. This exception
requires a Transaction with `extra.plaid.pending == true` and no retired aliases.
The booked row's alias-only archive path is excluded; no booked SourceRecord,
identity promotion or financial update occurs. Stream/type conflicts, duplicate
owners and uncertain pending state still block preparation. This lets the actual
preparation coordinator reach its cached-change journal while preserving the
ledger baseline. A later fresh booked observation can settle the same UUID through
the ordinary mapped-entry writer. The new regression tests remain unrun.

`candidate_entry_ids(after_id:, limit:)` exposes the same bounded candidate
inventory, including rows that block publication. The shared publisher restarts
verification from nil and reconciles retained identities. Finishing an earlier
page chain does not prove completeness if a new UUID was inserted behind its
cursor. This enumeration does not resolve blockers or advance a checkpoint.

## Required publication boundary

The internal identity publisher implements this boundary and is called by migration
preparation. It remains gated from automatic cutover: every legacy financial write
path must participate in an enforced writer fence. Changing
`ProviderMigrationControl.state` alone does not stop a queued or already-running
legacy processor. A connection lease alone does not protect against a legacy job
that never checks it.

After that fence exists, publication should follow this contract:

1. Quiesce and drain the old writer under the enforced fence. Lock the control, connection, original financial Account, ExternalAccount and retained AccountProvider in the shared lock order, then admit selected Entry and entryable rows without waiting on concurrent financial edits. Recheck the exact current link, selected source policy, credential realm, epochs, archive checksums and typed financial checksums.
2. Capture immutable encrypted `IngestionBatch` evidence with `origin_kind = 'migration'`, exact external account and resource context, and the reviewed plan format. Keep `sync_id` null. This is migration evidence, not an API fetch, provider coverage, upstream tombstone or cursor checkpoint. Record the verified quiescence and review provenance in the evidence contract; a UI-provided flag cannot assert that a fence was held.
3. Create SourceRecords and EntrySources for exact reviewed identities, retaining each existing Entry UUID. A separate typed relationship must distinguish a retired pending alias from a current observation. Keep immutable migration evidence referenced after the mutable SourceRecord advances to a later API batch. Replay must recognize identical evidence and reject changed identity or financial state; it must never update an old evidence payload to make it match.
4. Advance a separate financial-bootstrap checkpoint in the same transaction as evidence publication, without overwriting the legacy-row copier's progress or the provider's transaction cursor. Repeating a committed page is idempotent. Conflict or crash cannot skip a row. Reconcile the full candidate inventory and all retained UUIDs before recording financial bootstrap completion.

The SourceRecord model now accepts migration-origin observations only through the explicit [permanent identity evidence contract](financial-identity-evidence.md). Capture verifies the actual legacy session permit and source/financial context. Model validation and database guards retain the original proof after native observations advance; no fake provider Sync is created. `Ingestion::IdentityBootstrap` implements the page publication, checkpoint and final verification sweep in steps 3 and 4. Its completion includes exact identity/alias/type comparisons and forward/reverse candidate reconciliation, but still requires coordinated re-verification at cutover. The code and tests have not run. Foreign keys alone do not prove review or quiescence.

## Required native adoption behavior

The earlier LedgerWriter called the importer using external ID and source, then checked whether its returned Entry agreed with EntrySource. That check happened too late to choose a legacy UUID. An old row with only `plaid_id` could be duplicated or produce a mismatch after a different row was selected. The writer now resolves existing provider-origin mappings before publication and passes the typed identity result into the native importer.

Native adoption resolves the reviewed active EntrySource first. The importer revalidates the typed result, locks the Entry and its entryable, and checks account, source ownership, provider ID/alias relation and financial type before applying protection rules. Competing identities raise a conflict. Existing `plaid_id`-only rows remain on their UUID and retain their old identity columns. The migration itself changes no financial fields; later genuine provider updates retain protection semantics.

A retired pending alias is evidence-only on replay. An explicit booked observation may reconcile a still-current pending identity, but the native writer must never reapply an already retired alias to the booked Entry. Deletion uses the same exact identity resolver: a raw archived `removed` ID is not a newly observed provider tombstone. A reviewed current `plaid_id`-only mapping can authorize withdrawal without rewriting compatibility columns. Retired aliases and corroborating observations can withdraw their own evidence but cannot change the posted Entry. Missing legacy mappings stop exact removals.

Migration-origin adoption, archive-only aliases, source-evidence immutability, the enforced legacy fence, final inventory reconciliation and bootstrap publication require executable rollout acceptance. The internal publisher is sequenced by `MigrationPreparation`, separately from ordinary copier tasks and recurring sync; its verified result does not activate Plaid.

### Implemented read-only resolver API

`Ingestion::MappedEntryResolver` resolves an existing persisted observation; it never creates a SourceRecord, assigns Entry columns or imports financial values:

```ruby
resolver = Ingestion::MappedEntryResolver.new(
  external_account: external_account,
  account: financial_account,
  definition: Provider::AccountData::Plaid.definition
)
result = resolver.resolve(
  source_record: observation,
  kind: "transaction",
  external_id: exact_provider_id,
  entryable_type: "Transaction"
)
```

The definition is supplied by application code from the declared adapter. This API neither calls `Registry.fetch` nor enables a gated adapter. The caller must hold the actual publication fences through resolution and any later write.

| Result | Meaning | Required caller behavior |
| --- | --- | --- |
| `resolved?` | Exact active posting mapping and financial UUID verified | Pass the typed result as `resolved_entry:` with `native_identity: true` after fence/policy checks |
| `retired_alias?` | Explicit booked pending alias points to a later current ID | Preserve incoming evidence and skip financial publication; `result.entry` is intentionally nil |
| `unmapped?` | SourceRecord has no EntrySource history | Continue only through the controlled new-identity path after bootstrap completeness checks |
| `pending_transition?` | An explicit pending provider ID resolves to a current pending UUID | Import through the typed result and atomically retire the old observation after the new mapping succeeds |
| `Conflict` | Identity, ownership, type, origin or evidence history is inconsistent | Quarantine the batch; never fall back to a financial resemblance match |

Results also retain the exact account/source/definition context, `entry_identity`, `source_record_id`, `entry_source_id`, `current_external_id`, and the previous ID for a pending transition. Archived/deleted mappings are conflicts, not `unmapped`; their old UUID cannot silently become a new insertion. Corroborating `role = 'evidence'` mappings cannot select a posting. The resolver checks conflicting current external IDs and legacy Plaid IDs outside the selected UUID.

An old `plaid_id`-only Entry is accepted only through explicit `match_method = 'legacy_plaid_id'` mapping and compatible original identity columns. Resolution alone changes nothing. Existing explicit legacy pending metadata and validated permanent bootstrap aliases can produce `retired_alias`. The resolver accepts genuine provider observations or the explicit migration evidence contract, and validates retained bootstrap proof even after a newer provider batch becomes current. This integration and the internal bootstrap publisher have unrun tests.

### Implemented provider-origin publication

The native LedgerWriter resolves an existing mapping before updating the observation, enriching merchants or bootstrapping categories. It checks the resolved financial type and locks the existing Entry and entryable. Retired aliases return before financial or observation mutation; the newly captured immutable API batch retains the replayed input. `insert_only` and activity-label repair operate on the resolved UUID as well.

`Account::ProviderImportAdapter#import_transaction` and `#import_trade` now accept `native_identity: true` and an optional typed `resolved_entry:` result. A bare Entry, UUID, unrelated result or stale mapping is rejected. `MappedEntryResolver.for_import!` locks and re-resolves the durable mapping inside the import transaction. Supplied mappings skip legacy row selection and manual/pending guessing. Ordinary calls retain their old defaults and behavior. Native Trade imports enforce protection inside the importer as well as in the writer.

When a posted observation supplies a distinct `pending_external_id`, the writer resolves that exact current pending SourceRecord and Entry UUID. The native importer inspects protection before promotion. It advances external ID/source identity, appends the old ID to `auto_claimed_pending_ids`, and retains the original pending date. For protected Entries, amount, name, currency, labels and other financial values remain unchanged. Existing user-modified pending cleanup is retained; excluded/import-locked financial pending metadata can remain untouched. The explicit claimed alias still suppresses replay independently of that UI state. After import, the writer creates the new posting mapping to the same UUID and marks the old observation withdrawn/nonpending in the same transaction. A later failure rolls back the whole page's ledger/evidence changes.

Native manual/CSV duplicate candidates must have no external ID, Plaid ID, nonblank source or provider-backed EntrySource history. Protected unowned manual/CSV claims still retain their financial values. An exact old Plaid ID with no reviewed mapping raises a conflict instead of creating a new Entry. The native path disables the old amount/date-based pending auto-claim branch; explicit provider linking is supported, while any provider requiring a different reconciliation policy needs that policy and parity tests before activation. Legacy callers keep their existing pending behavior.

### Remaining bootstrap and rollout integration

1. **Verify the written permanent bootstrap provenance.** EntrySource now retains its original batch, external account, current/retired identity role, financial type and exact identity state. Signed evidence and exact composite relationships preserve the reviewed Entry UUID after `SourceRecord.ingestion_batch_id` advances. Archive-only aliases do not require protected legacy metadata changes. Execute the database/behavioral tests and complete signing-key rotation and trigger restoration acceptance before relying on that proof.
2. **Verify and integrate publication under the enforced legacy fence.** The internal `Ingestion::IdentityBootstrap` implements the transaction, checksum and bounded completeness contract, with capture/verification restart and retained original proof. Execute its tests and coordinate its final re-verification with the other cutover proofs before exposing it to operators. Do not run the normal LedgerWriter on a migration plan: provider coverage and accounting update semantics differ from a no-financial-change bootstrap. Native readiness must require successful financial bootstrap for each linked account, with no unresolved rows. Record quiescence through the actual fence, not a UI flag or control-state value alone.
3. **Verify migration-origin resolution against the retained proof.** The implemented resolver checks signed bootstrap evidence for migration observations and for permanent mappings whose latest observation is now provider-origin. It revalidates exact family/account/source/type and identity, with no financial resemblance fallback. Missing mappings conflict, and archive aliases yield the same positive suppression outcome as runtime aliases. Execute these tests against the real additive schema.
4. **Validate withdrawal and absence parity under the migration evidence contract.** TransactionWithdrawals now resolves current-versus-retired identities before changing observations. It withdraws the whole supplied set before considering financial deletion, making a posted ID and its old pending alias independent of removal order. Pending absence selects and excludes SourceRecord identities and routes through the same withdrawal command, including reviewed old `plaid_id`-only mappings. Other live evidence, reconciliation and field protection retain financial UUIDs; a locked Transaction `extra` also retains its pending metadata while source evidence records withdrawal. Immutable migration-origin alias handling is written; these paths still require executable concurrency/parity checks before activation. Generation retries must rebuild pending inventories from current identity outcomes rather than treating every raw pending ID as a current financial identity.
5. **Validate provider-specific reconciliation before activation.** Explicit pending links now promote the exact reviewed UUID before protection handling, and replay is suppressed before any financial effect. Providers without explicit links previously used amount/date pending guesses in the legacy importer. Native mode intentionally does not make those guesses; a separately declared reconciliation policy, ambiguity handling and provider parity tests are required where that behavior is necessary. Protected first-row imports also skip merchant/category side effects, so their category-bootstrap timing differs from the old eager Plaid matcher.

The cash importer itself does not return nil for a retired alias. The LedgerWriter now branches on the resolver's explicit outcome before calling it. Keep that positive suppression boundary during migration-origin integration; treating nil as a generic insertion fallback would recreate the original problem.

Integration tests must exercise the whole batch transaction: replay of an old `plaid_id`-only Entry; protected cash and Trade adoption; an explicit pending-to-posted transition; every replay ordering of current and retired aliases; conflict with another UUID; absent or stale bootstrap evidence; legacy writes racing bootstrap; manual/CSV similarity that must not claim a mapped provider row; and removal after adoption. Compare every retained Entry UUID and protected financial snapshot, not just final row counts. Force an error after mapping selection and verify that no partial financial, merchant, category or evidence mutation commits.

## Validation

The focused Minitest suites are `test/models/provider/account_data/plaid/identity_bootstrap_plan_test.rb`, `test/models/ingestion/mapped_entry_resolver_test.rb`, `test/models/ingestion/mapped_entry_publication_test.rb` and `test/models/account/provider_import_adapter_native_identity_test.rb`. They cover unchanged typed financial state and UUIDs, old/current identity columns, explicit pending aliases and suppression, unprocessed transitions, investment cash classification, absent/removed archive history, cross-stream and cross-page collisions, native-evidence conflicts, exact continuations, EU shared source identity, tenant isolation, unverified/active copies, protected publication, legacy defaults and full-page rollback. These tests have been added but could not be executed because this workspace has no Ruby/Bundler runtime. No migration or environment setup was run.
