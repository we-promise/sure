# Interactive Brokers account-data port

Status: native reader, normalization, statement codec boundary and pure historical
balance projection are written. Behavioral tests are written but have not run in
this workspace. `native_ready?` remains false; existing IBKR connections still use
the legacy pipeline.

The [captured historical command writer](../architecture/provider-historical-balances.md)
is now written as well. Its pre-materialization anchor repair and post-materialization
equity phases remain to be wired into account syncs and verified.
The [export archive and equity handoff](../architecture/provider-ibkr-export-protocol.md)
now restore exact provider-sync artifacts and produce immutable source references;
account scheduling and attachment remain explicit integration gates.

One connection holds a Flex query ID and token and may expose several account IDs.
One Flex XML export supplies inventory, balances, positions, trades, commissions,
cash movements and equity history. Native ingestion sends or polls once per call,
captures the encrypted reference as progress, and returns `coverage.available_at`
for a later poll. It never sleeps or retries inside that call. Redirects are refused.
XML parsing is strict, non-networked, size bounded and rejects document types,
conflicting account identities and cross-account section rows.

After download the first ready inventory page archives the XML. All slices carry its SHA-256 digest;
resuming an offset requires the exact original document. Inventory and holdings
slices contain at most 100 source groups; activity slices contain at most 100 source
rows, each of which can yield a trade plus a separate commission transaction. A
completed activity checkpoint identifies an export, and never suppresses the next
export's rows. Both trades and cash sections must be read before coverage is complete.

Normalization retains the legacy financial conventions:

- Holdings aggregate stock long-position tax lots by conid, report date and
  currency, with weighted per-share cost basis. IDs stay
  `ibkr_<account>_<conid>_<date>_<currency>`. Security lookup remains ticker-only;
  conid and ISIN remain source evidence, and do not silently change existing
  security resolution.
- `ibkr_trade_<tradeID>` purchases have positive amount and quantity; sales have
  negative amount and quantity. `ibkr_trade_fee_<tradeID>` is a separate cash fee in
  the commission currency. Embedded commission is not added to the trade amount.
- `ibkr_cash_<transactionID>` deposits are negative contributions, withdrawals
  positive withdrawals and dividends negative cash transactions. Provider FX rates
  retain exact decimals. Zero quantity stock trades are explicitly represented.
- Summary cash plus position value forms the current total. Base-summary rows take
  precedence over account-currency rows, matching the legacy parser.
- Historical equity totals override total account value after materialization,
  preserving calculated cash and separating all account trade flows from market
  movement. The pure projection carries totals across weekends through the captured
  anchor and excludes dates whose trade FX could not be resolved.

Before activation, implement and verify all of these boundaries:

1. Verify durable delayed polling and the retry disposition after the 20-poll budget
   together with the written original-sync XML archive and scoped resumption protocol.
   The observation clock remains frozen while the separate polling clock advances.
2. Wire the authoritative historical command writer before and after account
   materialization. Its written planner captures existing cash, all account trades,
   dated FX, protected dates and anchor state. Attach the exact equity handoff to a
   sealed account-sync input, serialize materialization, and complete the auxiliary
   equity-history table/payload transfer and ad hoc recalculation protocol.
3. Source evidence backfill that maps all existing IDs to their financial UUIDs,
   retains manual edits, protection, fees, labels and cost basis, and reconciles
   already-imported security identities before the first native write.
4. Explicit acceptance of stricter malformed-data handling: missing/ambiguous base
   balances, unsupported FX, invalid tax lots and conflicting prices retain the
   last financial state and fail the page. The legacy path sometimes supplied zero,
   skipped individual rows or accepted a group's first price. Complete holdings
   absence cleanup is deliberately disabled until verified.
5. End-to-end parity, restart, cutover and rollback tests in a provisioned Rails
   environment. No table migration or connection cutover has been executed here.
