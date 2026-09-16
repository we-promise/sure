# Captured Onchain MOEX history

MOEX dated-history acquisition is implemented in the current working tree;
tests are authored but unrun. Current-market quote acquisition remains gated on
unproved price/date semantics. This slice does not activate native Onchain sync,
accept upstream coverage or run a migration.

[FxAcquisition](../../app/models/provider/account_data/onchain_wallet/fx_acquisition.rb)
is a pure planner behind Assembly's captured `read` boundary. After the existing
five-day cached-rate lookup misses, a MOEX selection produces one
`fx_moex_history` operation per physical page. Other supported remote providers
retain their existing `fx_remote` operation and date policy.

[FxConfiguration](../../app/models/provider/account_data/onchain_wallet/fx_configuration.rb)
pins `MOEX_ISS_URL`, pacing and `moex-cets-dated-history/v1` through the live
configuration proof. There are no MOEX credentials. The reviewed instruments
are `USD000UTSTOM`, `EUR_RUB__TOM` and `CNYRUB_TOM`, always on the `CETS` board.
Only those foreign currencies crossed with RUB are supported. Other pairs
produce a captured `unsupported_pair` result without HTTP or an invented cross.

The [reader](../../app/models/provider/account_data/onchain_wallet/moex_fx_reader.rb)
requests `/history/engines/currency/markets/selt/boards/CETS/securities/INSTRUMENT.json`
with fixed `from=requested_date-10`, `till=requested_date` and an explicit `start`.
Each response has a one-MiB bound and at most 100 rows. The next offset advances
by that full page's 100 physical rows. A short or empty page terminates history;
a full final page at the 500-page ceiling raises incomplete history and cannot
produce a partial valuation. Existing aggregate wallet-operation/evidence bounds
also apply. No current-market endpoint, redirect, retry middleware, mutable
provider registry or shared-rate-table write is used. The HTTP client's underlying
Net::HTTP retry count is explicitly zero, as supported by the pinned
[HTTParty connection adapter](https://raw.githubusercontent.com/jnunemaker/httparty/v0.24.0/lib/httparty/connection_adapter.rb).

ISS columns are matched by name, case-insensitively. Duplicate names, missing
identity/date fields, mismatched row widths and unknown response shapes reject.
Only the exact board, instrument, `TRADEDATE`, `CLOSE` and `WAPRICE` columns are
retained. Every row must match the requested instrument and board, with a
canonical date in the ten-day interval. Decimal parsing never passes through a
binary float. `CLOSE` takes precedence; `WAPRICE` is used only when close is
absent. Nonpositive values cannot become a rate. Conflicting observations for
one date reject rather than selecting whichever page happened to arrive last.

The latest usable proved date wins. For RUB-to-foreign conversion, decimal
`1 / original_rate` is rounded to twelve places, matching the existing inversion
policy. The returned fact retains the original rate, instrument, board, selected
price field, direction and policy. Its captured request and raw dated rows remain
in the encrypted prefix; the derived quote retains the actual FX date and rate.
Ten-day remote history does not change the five-day cache or Twelve Data and
Frankfurter limits.

HTTP throttles and failures escape with sanitized errors before a fragment is
appended. A resumed same-Sync adapter reconstructs its successful prefix and
requests only the missing operation. A captured-but-unapplied page is reused
without another GET before requesting the next page. Request dates remain tied
to the original Sync while physical fetch timestamps retain the later wall time.
This supplies bounded successful page traversal, not a durable limit on repeated
failed transport attempts or installation-wide request quotas.

An empty history leaves valuation unavailable. The legacy current branch stamps
`LAST`, `WAPRICE`, `MARKETPRICE` or `LCLOSEPRICE` with `Date.current`; the native
planner deliberately does not reproduce that unsupported date assertion. Current
price-field/date proof would be required before adding that unsupported branch;
accepting history-only valuation is a deliberate migration parity decision. See
the [remaining FX design](provider-onchain-remaining-fx.md). Representative endpoint
fixtures and runtime acceptance remain unverified.

Ten reader/planner tests cover identity, exact numbers, inversion, dates, column
ambiguity, pagination, conflicts, bounds and transport admission. Two production
Syncer cases cover interrupted captured-page replay across midnight and empty
history leaving a balance unknown. These tests have not run in this workspace.
