# Financial identity migration inventory

`Provider::AccountData::FinancialIdentityManifest` records the reviewed legacy identity conventions for all 23 copied provider families. `Provider::AccountData::IdentityBootstrapPlan` implements read-only planning for the 22 families whose current `Entry.source` and `Entry.external_id` identify a financial row without reconstructing historical API responses. Plaid, including its EU offering, uses its [specialized planner](plaid-identity-bootstrap.md).

The financial identity is the retained financial Account UUID + exact source + exact external ID. It is scoped through the copied ExternalAccount UUID and identity namespace, retained AccountProvider UUID and revision, and family. An institution name is never an identity or ownership criterion. Additional sources covering that institution do not acquire these Entries merely because their dates or amounts agree.

The planner is an executable inventory and review interface. Planning leaves all existing Entry and entryable attributes untouched and creates no API requests, synthetic Syncs, provider checkpoints, SourceRecords or EntrySources. A separate internal [identity publisher](financial-identity-evidence.md) now consumes fresh plans under the legacy fence and creates evidence with a dedicated resumable checkpoint. It does not activate a provider. The new behavioral tests have not run because Ruby/Bundler are unavailable in this environment.

## Reviewed provider conventions

The source column equals the provider key in every row below. Tests check that each manifest source also equals the native adapter's declared source. `T` means an existing Transaction; `R` means an existing Trade. The stream distinguishes investment cash activities from banking transactions even when both use Transaction rows. Angle-bracket placeholders describe opaque persisted values, not values to recompute during migration.

| Provider key | Persisted external ID and financial type | Native stream | Retained account cache columns | Additional review requirement |
| --- | --- | --- | --- | --- |
| `akahu` | `akahu_<id>` or `akahu_pending_<MD5>`; T | transactions | `raw_transactions_payload` | Legacy collision suffixes require occurrence provenance. |
| `binance` | `binance_spot_<pair>_<id>` / `binance_futures_<pair>_<id>` / `binance_p2p_<order>`; R. P2P `_funding`; T | activities | `raw_transactions_payload` | Funding and trade are distinct financial records. |
| `brex` | `brex_<id>`; T | transactions | `raw_transactions_payload` | Exact copied card/cash source account. |
| `coinbase` | `coinbase_txn_<id>` and older `coinbase_buy_<id>` / `coinbase_sell_<id>`; R | activities | `raw_transactions_payload` | Old buy/sell endpoint IDs are not automatically aliases of current transaction IDs. |
| `coinstats` | `coinstats_<id>`; T or R | activities | `raw_transactions_payload` | Known exchange trade placeholders require financial type review. |
| `enable_banking` | `enable_banking_<transaction_id or entry_reference>` or stored content digest; T | transactions | `raw_transactions_payload` | Preserve the stored fallback ID; do not rehash edited fields. |
| `ibkr` | `ibkr_trade_<id>`; R. `ibkr_cash_<id>` and `ibkr_trade_fee_<id>`; T | activities | `raw_activities_payload` | Trade, cash and commission are separate identities. Historical balances have a separate evidence workflow. |
| `indexa_capital` | Raw `id` or `transaction_id`; T or R | activities | `raw_activities_payload` | Unprefixed IDs require exact source ownership. |
| `kraken` | `kraken_ledger_<id>`; T. `kraken_trade_<id>`; R | transactions / activities respectively | `raw_transactions_payload` | Ledger and trade resources remain separate. |
| `lunchflow` | `lunchflow_<id>` or `lunchflow_pending_<MD5>`; T | transactions | `raw_transactions_payload` | Legacy collision suffixes require occurrence provenance. |
| `mercury` | `mercury_<id>`; T | transactions | `raw_transactions_payload` | Only explicit stored pending aliases. |
| `monobank` | `monobank_<id>` or `monobank_pending_<MD5>`; T | transactions | `raw_transactions_payload` | Distinct hold/booked IDs are not inferred to be aliases. |
| `onchain_wallet` | `onchain_<legacy source account UUID>_<movement id>`; R | activities | `raw_movements_payload` | Retain the old UUID namespace. Unpriced Transaction placeholders require review. |
| `plaid` | Current raw external ID, older `plaid_id`, and explicit pending links; T or R | transactions / activities | `raw_transactions_payload`, `raw_holdings_payload` | Specialized archive-backed stream/alias classification; US and EU share source `plaid`. |
| `questrade` | `questrade_trade_<digest>` / `questrade_journal_<digest>`; R. `questrade_cash_<digest>` / `questrade_fee_<digest>`; T | activities | `raw_activities_payload` | Retain the persisted 24-character digest; never recompute it from edited money or description. |
| `redbark` | `redbark_<id>`; T | transactions | `raw_transactions_payload` | Only explicit stored pending aliases. |
| `simplefin` | `simplefin_<id>`; T | transactions | `raw_transactions_payload` | Investment account transactions still use this stream; the old investment transaction processor is a no-op. |
| `snaptrade` | Raw provider ID; T or R | activities | `raw_activities_payload`, `raw_transactions_payload` | Unprefixed IDs require exact source ownership. |
| `sophtron` | `sophtron_<id>`; T | transactions | `raw_transactions_payload` | No inferred pending state. |
| `trade_republic` | `trade_republic_event_<id>`; T or R | activities | `raw_timeline_payload` | Verify the exact currently linked cash/securities account after any legacy routing. |
| `trading212` | `trading212_order_<fill or order id>`; R. `trading212_dividend_<reference>` / `trading212_transaction_<reference>`; T | activities | `raw_orders_payload`, `raw_dividends_payload`, `raw_transactions_payload` | Keep the selected fill/order/reference ID exactly. |
| `up` | `up_<id>` or `up_pending_<MD5>`; T | transactions | `raw_transactions_payload` | Preserve stored fallback IDs and explicit pending aliases. |
| `wise` | `wise_transfer_<id>`, `wise_fee_<id>`, `wise_statement_<reference, id or digest>` with optional `_fee`, `wise_activity_<id>`, `wise_interbalance_<id>_inflow` / `_outflow`; T | transactions | `raw_transactions_payload` | Separate route identities are not automatically merged. |

These conventions were audited against the legacy Entry processors and the corresponding native normalizers. The manifest tests cover every provider key, each resource/type form, source declarations, and the existence of the declared financial cache columns in the lossless account migration manifest. They do not establish runtime financial parity or upstream API guarantees.

The copier retains the complete typed legacy account row, not just the cache columns listed here. Those columns document the available historical evidence. A latest cache can be partial, empty, or absent for an old financial row; its absence never means that the Entry should be deleted. The generic planner uses the archive to prove copied source account ownership and unchanged source state. Accordingly its `archive_paths` is empty: it does not claim to have located every historical Entry in an API export.

## Read-only API and output

```ruby
manifest = Provider::AccountData::FinancialIdentityManifest.for(provider_key)
planner = Provider::AccountData::IdentityBootstrapPlan.new(mapping: mapping, family: authorized_family)
page = planner.page(cursor: nil, limit: 100)
ids = planner.candidate_entry_ids(after_id: nil, limit: 500)
```

`page` returns immutable `document`, `next_cursor`, and `complete` values; `ready?` means that this page has no blockers. Its format is exactly `provider-financial-identity-plan-v1`. The public candidate enumeration validates the same copied context and uses the same predicate as the planner, including blocked rows. UUID ordering is an enumeration mechanism, not a change feed: a final quiesced sweep must start again from `nil` to catch rows inserted behind a prior continuation.

Each accepted row includes the exact Entry UUID and entryable type; `kind` (`transaction` or `activity`); current external ID; explicit pending aliases; original `source`, `external_id` and `plaid_id` columns; and typed snapshots of every Entry and Transaction/Trade attribute. This retains amounts, currencies, dates, categories, merchant references, import and reconciliation links, split/transfer relationships, labels, metadata and protection flags. A SHA-256 checksum covers the typed financial snapshot. The encrypted copied account archive has its separate existing keyed checksum.

The row's `identities` array contains an exact `external_id`, `input_external_id`, `input_occurrence`, `role`, and `pending` flag for each source identity. The current identity has role `current`; explicit former IDs have role `retired_alias`. Stable, exact IDs use occurrence zero. Retired aliases are evidence that suppresses recreation of the old pending Entry; they are not additional financial rows or permission to reapply pending values to the booked Entry.

The page binds provider/source/version, family, connection and ExternalAccount UUIDs, upstream account ID and namespace, financial Account and AccountProvider UUID/revision, account currency/type, migration mapping UUID, archive checksum, copy run, connection realm, credential revision and writer epochs. Continuations must match that context. A changed archive, ownership conflict, wrong family, enabled connection or unverified copy aborts planning. Per-row ambiguity supplies a blocker and no continuation. The planner never changes a row to make it match.

## Explicit unresolved cases

- Only `Transaction.extra.auto_claimed_pending_ids` supplies generic retired aliases. Other-provider flags, malformed pending JSON, unsupported pending states and aliases crossing a reviewed stream/source convention block adoption. Plaid's additional explicit provider link remains in its specialized planner.
- Akahu and Lunch Flow allocated fallback suffixes according to existing database collisions. Native input occurrence reflects positions in a response. Those are different facts: every suffixed fallback, and a base ID with a surviving collision sibling, blocks until exact provenance is reviewed. Amount/date/name similarity cannot supply it.
- Onchain unpriced, excluded zero-value Transaction placeholders cannot silently become Trades. CoinStats exchange Transaction placeholders with stored trade-type metadata likewise require review. An accepted Transaction mapping still cannot authorize a later Trade observation; the native resolver rejects type conflicts while retaining the old UUID and money.
- Missing IDs and recognizable provider-prefixed IDs with missing or conflicting sources remain in the candidate inventory as blockers. Indexa and SnapTrade use unprefixed IDs, so an otherwise manual Entry cannot be attributed to them from its ID alone. Such historical ownership repairs require a separate explicit reconciliation before declaring a complete migration.
- Coinbase's old buy/sell endpoints and current transaction endpoint, and Wise's multiple routes, may expose related economics under different IDs. This planner preserves those IDs separately and does not invent cross-endpoint aliases. Any necessary overlap reconciliation remains a provider-specific activation gate.

## Bounded reads and publication gates

A page has at most 500 Entries, a 16 MiB scalar database preflight for selected Entry and Transaction/Trade rows, a 32 MiB legacy account row preflight, and a 96 MiB typed output budget. `MigrationCopier.snapshot_for(mapping, max_bytes:, max_chunks:)` additionally supports optional positive integer bounds; this planner passes 32 MiB decoded bytes and 1,024 chunks. The reader inventories IDs and stored byte sizes before loading encrypted payloads, rejects an oversized inventory, decodes one chunk at a time, checks the exact cumulative decoded size, and verifies the existing checksum. Default callers retain their previous uncapped contract. Legitimate chunks are produced by the existing copier's maximum 1 MiB source chunk writer; the limits are not a general defense against externally forged encrypted compression payloads.

Read-only previews can race with source or financial edits. Scalar preflights limit the observed database rows; they are not a transaction-wide memory guarantee against concurrent growth. Publication must admit and lock the exact rows and replan under the actual legacy fence. Private snapshots belong only in encrypted evidence, never logs or ordinary JSON metadata. The [permanent identity evidence contract](financial-identity-evidence.md) defines source binding and proof retention. `Ingestion::IdentityBootstrap` now implements atomic page publication/checkpointing and a fresh verification sweep with forward/reverse inventory checks. These paths are written but unrun; operator integration, coordinated cutover re-verification, runtime execution and all-provider parity remain acceptance gates.

The scalar preflight also rejects a Transaction or Trade shared by several Entries, including another page or family. Such a row has ambiguous financial ownership; counting it once would also understate the size of repeated snapshots. Unsupported polymorphic types are blocked without loading their payloads.

Each page revalidates the copied archive and performs cross-page identity/alias checks. The implementation favors bounded correctness; it has not been benchmarked. Repeated archive validation can cost page count multiplied by archive size, and alias scans need realistic large-account measurements before claiming growth performance. Any future revision/checksum cache must preserve the final locked revalidation contract.
