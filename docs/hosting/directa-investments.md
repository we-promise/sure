# Directa investment preview

Directa uses one native Investment account with a brokerage cash component.
Its balance is cash plus the market value of the securities. Do not add the
same brokerage liquidity as a separate Depository account: that would count it
twice. Trading availability and margin buying power are separate figures and
do not populate cash.

## Connection

This self-hosted preview is available to administrators with Preview features
enabled. Open **Settings → Providers → Directa**, or select Directa when adding
an Investment account. Enter the Directa account number and password, then the
one-time code if Directa requests one.

The password is used only for that login request. Sure stores the verified
session and any short-lived OTP challenge with Active Record encryption.
Explicit encryption keys must be configured before login is allowed. OTP state
belongs to the initiating Sure session, expires locally after five minutes,
and permits at most three code submissions. Reconnecting preserves a previous
verified session until the replacement passes account identity checks.

No additional browser or container is needed. Requests use fixed Directa HTTPS
routes and a certificate-verified TLS trading connection. The client only
implements authentication, account and instrument metadata, portfolio and
executed-order history reads, statement exports and heartbeats; it has no order
submission or cancellation commands. This is an
application restriction, not a bank-issued read-only permission on the session.

## Snapshot behavior

Authentication and a completed portfolio import are separate states. A newly
authenticated connection stays pending its first complete, verified snapshot;
authentication alone does not create a successful holdings import.
Once the import completes, **Directa** appears under Investments. Manual sync
is separate from the optional **Sign in again** form; a connected session does
not need another login merely because its first snapshot is pending.

Cash comes from Directa's Liquidità field in EUR, as defined in its
[availability documentation](https://www.directa.it/help-supporto/marginazione-shortselling/disponibilita-real-time-come-funziona).
Sure's existing Holdings view displays it as **Brokerage cash**; a debit remains
visible as a negative cash balance.

Positions require complete stream framing, an exact instrument identity and a
verified market value. The stream's average purchase price is not a current
market quote. Missing valuation, unsupported instruments, sequence gaps,
identity changes or partial responses preserve the previous portfolio rather
than publishing a partial total or deleting holdings.

The supported reference-price path uses Directa's instrument metadata and a
fresh account-verified bootstrap. It recognizes the evidenced ordinary Milan
ETF/ETC, Xetra ETF, Milan MOT bond and Nasdaq share combinations. Unknown
instrument combinations stop the whole import instead of assuming stock
pricing. Quantities, multipliers and reference prices determine the value;
supported bonds use a quotation divisor of 100. Ordinary foreign-currency
positions use Directa's bootstrap `cambioBCEdef` conversion, with no fallback
when the required rate is missing or invalid.

These are observed valuations using bank reference prices, not a live quote
feed. The encrypted position metadata preserves the reference-price source,
original quote currency and price, multiplier, quotation divisor, observation
time and any conversion used. The quote's trade date and the FX effective date
remain unknown. The observation date is not promoted to either date, and this
path does not write historical prices or exchange rates to shared tables.
Cash-only complete snapshots use the same native account model.

Holdings charts start with the first observed Directa snapshot and carry its
values forward until a later snapshot replaces them. They do not reconstruct
earlier holdings or substitute shared market prices for the observed values.
Generated chart rows are checked against their provider-owned source before a
later import can reuse them; manual or foreign-provider holdings remain conflicts.

Existing family synchronization discovers eligible Directa connections through
the standard provider flow. Stopping syncing clears its session and pending
login challenge while retaining saved financial records. Expired bank sessions
require another attended login; automatic renewal has not been established.

Portfolio refreshes have a five-minute minimum interval. A portfolio or activity
history request that receives HTTP 429 stores a connection-wide retry deadline;
the provider's `Retry-After` value is honored up to seven days, with a 15-minute
fallback when the response has no usable deadline. Portfolio and history reads
share a per-connection lock, while their five-minute attempt intervals remain
independent so the normal history job can run after a portfolio refresh. A
concurrent job that cannot acquire the lock exits before making bank requests.
A throttled request leaves the existing session, portfolio and Activity
unchanged. No bank quota is assumed and no automatic retry schedule is added.

## Unrealized return

For supported products with unit multiplier one, Sure imports the bank's
average purchase price as per-unit cost basis. Percent-quoted MOT bond averages
divide by 100. Foreign-currency basis uses the same current bank conversion as
the observed market value. The encrypted snapshot records that methodology;
acquisition-date FX and tax basis are not inferred.

The UI calls the result **Unrealized return**. It compares current reference
value with the average price of the positions still held. It excludes realized
results, income, charges and historical FX performance. Missing or unsupported
bank averages remain unknown, including after Activity is imported. A partial
history of buys must not manufacture a cost basis. Aggregate views disclose
when some holdings have unknown basis and are excluded.

## Activity

After a successful portfolio sync, a separate bounded job reads executed orders
and the corresponding monthly statement exports using the saved verified
session. The initial request covers 2018-01-01 through the last completed bank
day; later syncs recheck overlapping recent months and any coverage gap. This
is a requested range, not a guarantee that Directa retains all historical data.

Sure matches statement executions to fully executed buy/sell orders, reconciles
quantities and groups fills by order and transaction day. Activity records use
the statement's actual EUR gross amount and separately reported commission,
including when the original quote is USD or a percent-quoted bond. An empty
commission cell means no separately allocated commission, not proof that every
charge is included. Other cash movements, dividends, coupons and taxes are not
part of this executed-order import.

Pagination requires an explicit empty final page. Identity and connection
generation are checked, and two complete normalized reads must agree before
anything is saved. An encrypted account ledger preserves stable identities and
detects changed or disappearing bank data. Repeated syncs preserve existing
entries, including user edits and deletions. History failures are reported
separately and retain the last successful portfolio and Activity.

Directa trades belong to the brokerage account and retain their cash impact.
Older Activity does not extend the portfolio chart before its first observed
snapshot, reconstruct earlier positions, or publish shared historical prices.

## Current verification boundary

Authentication responses, stream semantics and valuation formulas were
recovered from Directa's distributed clients. An attended account login and
subsequent saved-session reads established complete position and cash responses.
The supported valuation rules are intentionally limited to the evidenced
instrument combinations; they do not establish support for every Directa
product. Executed-order and statement reads were verified against a saved
session, including multiple fills, EUR and USD quotes, bonds and commissions.
General cash-ledger imports, intraday price feeds and paid market-data activation
are outside this preview.
