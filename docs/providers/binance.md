# Binance account data

The native `Provider::AccountData::Binance` package remains disabled by its
readiness gate. Its adapter and bounded-reader tests have not run in this
workspace because Ruby is unavailable. Existing Binance imports remain active.

The adapter retains one `combined` account. Spot, margin, Simple Earn flexible,
Simple Earn locked and USD-M futures remain separately identified observations.
Spot uses free plus locked units; margin uses net assets including debt; futures
uses wallet balance plus unrealized profit. Earn sums its flexible and locked
units per asset. All quantities and monetary inputs use exact decimal parsing.
No legacy importer, processor or model is called by the native adapter.

Inventory consumes one endpoint response per page. A failed source retains its
last complete normalized snapshot; an unfinished Earn page chain never replaces
that snapshot. An unavailable source with no previous evidence blocks portfolio
valuation. Successful empty sources remain empty. Rate limiting defers later
requests in the same sync. Original responses are retained in encrypted batch
evidence, separately from normalized source snapshots.

Balance valuation processes one asset per page and publishes the total only
after the chain completes. Stablecoin parity, USD total rounding and conversion
to the family's currency follow the current integration. A missing asset price
or exchange rate reports incomplete valuation. It does not create a zero price
or label an unconverted USD amount with another currency. Captured rate dates
and stale-rate information remain available with the valuation evidence.

Holdings retain `binance_<asset>_<source>_<date>` observation IDs and the captured
family date. Spot/futures trades retain `binance_<market>_<pair>_<id>`, legacy
entry amount signs, exact quantities, USD quote conversion and commissions.
Existing trades retain their financial fields. P2P emits the trade and its
`_funding` transaction together in one atomic group, retaining native fiat,
net crypto quantity and the fiat equivalent of the crypto commission. If either
leg already exists, shared ingestion preserves the legacy group's disposition.

History uses separate ID or time-window requests. Initial spot windows cover
24 hours; futures windows cover seven days and retain the existing 180-day
initial lookback. A saturated window continues by trade ID so trades sharing the
last timestamp are not discarded. Compact checkpoints retain pair IDs and the
P2P timestamp only after the batch is applied. P2P traverses both sides and its
30-day windows even when there are no current spot holdings. The 1,000-row trade
limit and allowed parameter combinations are described in Binance's
[account trade API](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/account).
Earn pagination uses explicit numbered pages of up to 100 positions, as specified
in the [Simple Earn API](https://developers.binance.com/en/docs/catalog/investment-and-services-simple-earn/api/rest-api/flexible-locked).

Activation still requires:

- Executed runtime tests, representative shadow comparisons and cutover checks.
- A bootstrap from encrypted legacy archives for source snapshots, separate Earn
  sides, previously observed pair IDs and sold-out assets. Native checkpoints
  preserve these once supplied; the factory does not infer them from old models.
- Explicit reconciliation for legacy non-`combined` account rows. They retain
  their existing identities and links; this adapter refuses to collapse them
  into or duplicate the combined portfolio.
- Reviewed same-security holding consolidation. Several Binance source
  observations can share one financial holding's composite identity. The shared
  writer rejects a silent overwrite. Consolidation must first establish that
  the source scopes are disjoint, preserve the existing holding UUID and retain
  all source evidence.
- Completed source-snapshot reconciliation for current-date holding absence.
  Failure and missing prices must retain positions; historical/future rows
  require an explicit disposition. The adapter does not authorize deletion.
- Verification of P2P status coverage and full API permission coverage. The
  existing projection does not filter P2P rows by status, so that behavior must
  be assessed against captured responses before activation.
