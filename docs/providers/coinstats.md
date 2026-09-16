# CoinStats account data adapter

The native adapter and bounded reader are written, but **native activation remains
disabled**. The Minitest cases have not been executed in this workspace. Existing
CoinStats jobs, accounts and processors remain the production path.

## Source topology and copying

A CoinStats connection owns one API key and can expose wallet assets, older
per-asset exchange accounts, combined exchange portfolios, and synthetic DeFi
positions. They share the account-data contract; endpoint routing is an explicit
source descriptor rather than an account name or a monetary payload heuristic.

`MigrationCopier` stores a reviewed projection in encrypted
`ExternalAccount.sensitive_details.source_descriptor`, and compares that projection
again during verification. The descriptor retains source kind, exact asset and
wallet identifiers, address and blockchain, exchange portfolio routing, DeFi
protocol/investment/title fields, fiat classification, presentation fields and the
legacy account UUID used by merchant identity. It excludes credentials, prices,
quantities and unrelated payload fields. The complete original typed row remains
in the encrypted, checksummed migration archive. Ambiguous routing fails copying.

External identity is the exact JSON array of `account_id` and `wallet_address`
name/value pairs, including null wallet values. Preserve case and spelling. Neither
asset symbols nor institution identity merge different wallets or portfolios.
Inventory currently enumerates reviewed existing descriptors; shared enrollment and
DeFi discovery must create descriptors before new sources can join this path.

## Native behavior

- Each reader method makes one HTTP request, parses decimal JSON numbers as
  `BigDecimal`, rejects oversized/malformed responses and redirects, and emits
  sanitized errors. Rate limits retain a bounded numeric retry delay. HTTP 409 has
  a distinct readiness error. Ordinary reads never start upstream sync jobs.
- Wallet histories are requested for one address and blockchain at a time. The
  legacy bulk response could be a flat transaction list without wallet ownership;
  coin-only filtering could put one wallet's movement into another wallet.
- Exchange balance pages stage all components before publishing a total. Encrypted
  continuations retain exact values, original observation time and a fingerprint
  of the source descriptor. A changed routing descriptor invalidates continuation.
  Duplicated assets invalidate the aggregate. Completed encrypted valuations supply
  subsequent holdings without repeating portfolio HTTP reads.
- Wallet quantity and price remain separate from fiat account value. Fiat assets
  contribute cash; combined portfolios include fiat cash and crypto positions.
  Currency maps take precedence over USD conversion; converted values retain the
  actual dated FX evidence. Missing exchange FX does not relabel USD as the family
  currency. DeFi `asset.price` is the total position value, so unit price is total
  divided by quantity. DeFi keeps actual USD when conversion is unavailable.
- Holdings retain `coinstats_holding_<asset>_<date>` or
  `coinstats_holding_<portfolio-asset>_<coin>_<date>`, quantities, prices and cost
  basis. Existing Crypto-only holding behavior is retained. Future holdings are
  never deleted. Complete portfolio reads expose their legacy same-day pruning
  requirement but do not authorize generic absence deletion.
- Transactions and trades use the activities stream with an explicit ledger
  representation. Wallet cash inflows are negative and outflows positive. Exchange
  buys retain positive trade amounts/quantities; sells retain negative
  amounts/quantities. Portfolio swaps preserve the legacy selected negative crypto
  leg. Fees already represented by upstream values are not added a second time.
- Entry IDs remain `coinstats_<hash.id>`, then the first nested item ID, then the
  legacy stable-fields digest. Its binary-float spelling is reproduced only in
  the identity preimage; financial amounts stay exact. Explicit archived-payload
  normalization permits historical Float values without weakening live parsing.
  Market-dependent values remain excluded from fallback IDs.
- Native activity publication is insert-only, reflecting the old first-seen raw
  transaction cache. Existing user changes retain precedence. Legacy cash metadata,
  labels, merchant IDs and notes are represented in canonical metadata. A historical
  Transaction becoming a Trade is a quarantined type conflict. The new writer must
  retain the original Entry UUID instead of reproducing the old delete/recreate.
- Histories use fixed windows, 100-row pages and at most 20 requests per account
  stream per run. Continuations bind account, descriptor, currency, endpoint and
  dates. Repeated IDs invalidate completeness; empty initial history requires
  readiness. The current 10,000-row and 2 MiB cursor limits fail closed; larger
  histories need shared window subdivision or durable generation staging.

## Remaining cutover work

1. Execute adapter, HTTP reader and copier/writer preservation tests against the
   shared schema; compare captured production-shaped wallet, exchange-asset,
   portfolio and DeFi payloads with the old path. No actual migration or cutover
   has been run by this implementation task.
2. Coordinate upstream wallet/exchange/portfolio refresh, pending readiness and
   API-key quotas across every consumer. Port the exchange-to-portfolio history
   fallback through a staged generation restart; never switch endpoints after
   publishing some pages. Retain polling/readiness evidence for replay.
3. Resolve the host transition explicitly. The current client retains the existing
   installation's `openapiv1.coinstats.app` base URL. Current official examples use
   `api.coinstats.app/v1`; verify endpoint/account compatibility before changing
   host or enabling the native reader.
4. Backfill SourceRecord/EntrySource/HoldingSource identities from archived rows,
   retaining financial UUIDs, first-seen cached values, locks, categories, transfers
   and merchant identities. Review historical duplicate fallback IDs, mixed wallet
   bulk data and Transaction/Trade conflicts. Supply explicit identity aliases for
   legacy name/symbol-based account matches that lack a stable provider ID.
5. Implement source-scoped complete-snapshot absence handling for portfolios and
   DeFi. Missing positions, failed reads, partially understood responses or failed
   upserts cannot zero active accounts or remove other-source/user-protected data.
   Include discovery/enrollment and the existing CoinStats unlink behavior that
   removes source rows while preserving financial accounts and history.
6. Verify delayed portfolio completion against the shared balance runner. Empty
   incomplete balance pages now persist fetch progress without changing money or
   currency. `balance_policy.anchor_date = "balance_date"` binds the anchor to the
   captured valuation date, including across a later Sync; a newer existing anchor
   cannot be replaced by that older observation. Holdings still reject a stale
   valuation rather than presenting it as a fresh snapshot. Durable complete
   portfolio/holding handoff and fresh revaluation remain acceptance requirements.
7. Review intentional divergences: exact decimals instead of Float arithmetic;
   quarantine instead of unknown-value zero; explicit FX instead of mislabeled
   scalar values; exact source matching instead of substring account names; no
   destructive Transaction-to-Trade replacement; no forced downgrade of an existing
   market-data Security to `offline`. These require financial parity decisions,
   not silent activation. Shared merchant descriptors now forward `logo_url` to
   the existing merchant resolver; its focused behavioral tests remain unexecuted.

Official endpoint references checked on 2026-09-15:
[wallet transactions](https://coinstats.app/api-docs/openapi/get-wallet-transactions/)
documents pagination, currency/window arguments and the pre-sync HTTP 409;
[portfolio coins](https://coinstats.app/api-docs/openapi/get-portfolio-coins/)
documents explicit portfolio scope and coin pagination;
[wallet DeFi](https://coinstats.app/api-docs/openapi/get-wallet-defi/)
documents address/chain scope and nested protocol positions.
