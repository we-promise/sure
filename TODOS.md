# TODOs

## V2: Period Return FX accuracy

**What:** When computing `period_return_trend`, the absolute_return SQL uses
`COALESCE(er.rate, 1)` — if an exchange rate is missing for a given (currency, date)
pair, it silently treats the conversion as 1:1.

**Why:** This can understate or overstate Period Return % for families with
foreign-currency investment accounts when a historical rate is unavailable in the DB.
The same 1:1 fallback behavior applies everywhere in the codebase (Portfolio Value,
Balance Sheet, etc.) for consistency. A warning is already logged by
`ExchangeRate.rates_for` when a rate is missing.

**How to apply:** In a future pass, consider surfacing the no-data state (`return nil`)
when any required FX rate cannot be found, rather than silently falling back. This
would require bypassing `ExchangeRate.rates_for` (which hides the nil-ness) and
checking `find_or_fetch_rate` directly. Coordinate with the broader FX accuracy
initiative so behavior is consistent across all money calculations.

**Affected file:** `app/models/investment_statement.rb` — `period_return_trend`
