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
implements authentication, account and instrument metadata, portfolio reads and
heartbeats; it has no order submission or cancellation commands. This is an
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

## Current verification boundary

Authentication responses, stream semantics and valuation formulas were
recovered from Directa's distributed clients. An attended account login and
subsequent saved-session reads established complete position and cash responses.
The supported valuation rules are intentionally limited to the evidenced
instrument combinations; they do not establish support for every Directa
product. Investment activity history, cash movements, intraday price feeds and
paid market-data activation are outside this preview.
