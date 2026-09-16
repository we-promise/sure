# Captured historical balance commands

Status: shared typed commands, input capture, FX capture, IBKR planning, the
fenced writer and account-job integration are written, with unrun behavioral tests.
The migrations have not been run and no provider has been activated. The legacy
IBKR hook remains for unmigrated owners and now enters the legacy ownership fence.
The [IBKR export protocol](provider-ibkr-export-protocol.md) now implements original
artifact restoration, fenced equity-source capture and exact typed handoff resolution.

Historical equity is a separate authority from current balances. The writer
requires the active `historical_balances` source policy and its exact revision.
Opening-anchor repair additionally requires the same source to own `balances`,
and captures that policy's revision separately.
There are two ordered operations: repair an eligible default opening anchor before
materialization, then apply provider equity totals after materialization. Repairing
the anchor afterward would leave the just-calculated cash history inconsistent.

The immutable source is an `IngestionBatch` with stream `equity_snapshots`, mode
`snapshot`, complete true, scope `account:<ExternalAccount UUID>`, the exact external
account, original ProviderConnection sync, writer epoch and historical source-policy
ID. Its encrypted payload is `Provider::AccountData::Ibkr::EquitySnapshot#payload`.
The pure value contains the sealed Flex export's equity rows and normalized balance:

```ruby
equity = adapter.historical_equity(account: account_record)
snapshot = Provider::AccountData::Ibkr::EquitySnapshot.new(
  external_id: account_record[:external_id],
  currency: equity.fetch(:currency),
  equity_rows: equity.fetch(:rows),
  statement_sha256: equity.fetch(:statement_sha256),
  observed_on: captured_observation_date,
  imported_current_balance: normalized_balance_record[:balance]
)
```

The source capture must run under the provider's existing fence and retain the
original XML artifact identified by its digest. Finish the account's source streams
before scheduling materialization. Pass the exact source-batch ID to the account
child sync; querying whichever source snapshot happens to be latest would mix
different exports or epochs.
Use `Ibkr::EquityCapture` for runtime capture; it adds the original artifact and
account-link revision to the encrypted value and returns the exact typed handoff.

`Provider::AccountData::Syncer` dispatches `Ibkr::AccountHandoff` only after complete
inventory and successful required account streams. The helper captures the exact
equity source and queues a sealed account job. The account execution path is:

```ruby
# Outside the financial transaction, capture market data and all-account trade FX.
snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: account)
# Account::SyncPreparation persists snapshot.payload once for this sealed Sync.

# Inside connection -> Account -> Sync -> source/financial row locks:
plan = Ingestion::HistoricalBalances::IbkrPlan.new(
  external_account: external_account, source_batch: source_batch,
  capture_revision: account_sync.id, trade_flow_snapshot: snapshot
)
Ingestion::HistoricalBalances::Writer.new(batch: plan.capture!(phase: "opening_anchor")).apply!
ExchangeRate.with_cached_rates_only { materialize_balances }
Ingestion::HistoricalBalances::Writer.new(batch: plan.capture!(phase: "equity_history")).apply!
# account_materialized_at commits atomically with all three phases.
```

Without a typed `TradeFlowSnapshot`, `equity_history` capture refuses to run inside
a database transaction. The account job captures every trade, including manual,
other-source and protected trades, and resolves missing FX before financial locks.
The snapshot validates those trade inputs again before projection. Stored trade-specific rates take precedence, with
their persisted legacy Float conversion preserved explicitly; fresh rate resolvers
must return exact decimals and their actual dates. Missing or invalid custom rates
exclude the entire affected date and leave that materialized balance untouched.
Its actual retained end balance also supplies the following day's starting value.
An affected date inside the projection without a materialized row blocks capture.
The captured command retains all trade/FX evidence and never calls a market API
during application. Native account materialization permits exact or recent cached
FX only, with shared locks on the selected rate rows. A missing, invalid or negative
rate aborts all three phases; the legacy materializer's 1:1/skipped-entry fallback
does not publish a partial native calculation. A later retry may use newly cached
materialization rates; the immutable trade-FX preparation remains the same. A new
account Sync is needed to capture different trade inputs or trade FX.

Commands also retain an exact snapshot and fingerprint of the account, every entry,
trade, valuation and balance input. The account job pins the connection and original
provider Sync before Account and child Sync; source/link/policy and financial locks
follow. Standalone command application takes connection, account, external-account,
link, policy, batch and financial-input locks, rechecks source ownership and epoch, then
compares that fingerprint. A changed cash balance, newly imported trade, manual
edit, new protection, relink or source-policy change rejects the stale command.
The account-link revision is pinned, and the writer locks the existing link and
policy rows so a direct relink cannot race the financial write.
Capture a new command after recalculation; captured evidence cannot be edited.

The opening-anchor heuristic matches the legacy trigger: its creation day matches
the account's, its value equals the imported current total, and non-valuation
history exists after its date. The shared writer additionally preserves protected,
reconciled and locked valuations. It updates an eligible anchor through
the existing opening-balance manager without changing Entry or Valuation UUIDs.

Daily balance upserts preserve existing Balance UUIDs and creation timestamps.
Materialized cash is retained, all account trade flows are separated from market
movement, and totals carry across weekends through the captured anchor. Protected
valuation dates keep their already-materialized value; that retained value also
becomes the following day's starting non-cash value. Protected dates lacking a
materialized balance block projection. Current account caches, holdings and
financial entries are otherwise untouched by the historical operation.

Failed-FX continuity is an intentional correction to the legacy projection: the
legacy loop skipped writing the failed day but used its unapplied IBKR total as
the next day's starting value. The shared projection uses the balance that remains
in the ledger, preserving continuity without inventing an exchange rate. The
failed day's row and financial entries retain their UUIDs, values and timestamps;
only subsequent projected performance differs. Activation still requires review
and execution of the three-day retained-balance regression coverage.

Applied commands are idempotent. The account-sync UUID distinguishes a later
recalculation, which may have newly available FX, from a retry that must reuse its
captured rates. If materialization runs again, capture a new
command from its new input fingerprint afterward. Returning an already-applied
command alone would not restore an override that a later materializer replaced.
Account jobs now use a session advisory lock spanning preparation, publication and
finalization, plus a predecessor chain. A crashed job resumes its own input set;
a committed `account_materialized_at` skips repeat materialization. Direct callers
that bypass `Sync#perform` are outside that execution fence and must be drained
or audited before cutover.

Remaining acceptance work:

- Execute the new queue, immutable-input, crash-recovery and actual materializer
  tests against Rails/PostgreSQL. The test code is present; passing runtime evidence
  is still required before claiming this integration is operationally verified.
- Verify full financial parity and dates where protected valuations or failed FX
  intentionally preserve materialized values. The stricter invalid-row projection
  remains an explicit acceptance gate.
- Coordinate the account materializer and legacy writers with migration ownership,
  and execute cutover, restart, race and rollback tests in Rails/PostgreSQL.
- Measure bulk/rapid account edits across distinct dates: sealed pending windows
  no longer widen, so those requests can queue multiple calculations. Pending
  supersession/coalescing is a separate optimization from serialization of running
  jobs; the implementation does not claim unchanged scheduling throughput.
- Verify all three PostgreSQL immutability triggers are installed and enabled in
  the acceptance database and deployment/restoration path. Rails `schema.rb` does
  not preserve functions or triggers. `Account::SyncDatabaseGuardsTest` fails
  visibly when a schema-loaded database omits these guards. Use the migration or
  an explicitly reviewed restoration procedure; the schema format is unchanged.

The new migration refuses to roll back while Account predecessor chains exist.
Draining workers and explicitly deciding retention/export/removal of that history
is required before reverting the schema; it never rewrites those references for
the operator. No migration or rollback has been executed here.
