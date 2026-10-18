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

Cash comes from Directa's Liquidità field in EUR, as defined in its
[availability documentation](https://www.directa.it/help-supporto/marginazione-shortselling/disponibilita-real-time-come-funziona).
Sure's existing Holdings view displays it as **Brokerage cash**; a debit remains
visible as a negative cash balance.

Positions require complete stream framing, an exact instrument identity and a
verified market value. The stream's average purchase price is not a current
market quote. Missing valuation, unsupported instruments, sequence gaps,
identity changes or partial responses preserve the previous portfolio rather
than publishing a partial total or deleting holdings.

The current recovered transport resolves instrument metadata but does not yet
supply verified exchange MICs and dated market values. Non-empty portfolios
therefore remain awaiting valuation until that source is validated and wired.
Cash-only complete snapshots can use the same native account model.

Existing family synchronization discovers eligible Directa connections through
the standard provider flow. Stopping syncing clears its session and pending
login challenge while retaining saved financial records. Expired bank sessions
require another attended login; automatic renewal has not been established.

## Current verification boundary

Authentication responses, stream semantics and instrument schemas were
recovered from Directa's distributed clients. A public TLS handshake and local
behavioral tests do not prove a real account login or portfolio import. The
first attended account validation remains required. Investment activity history,
cash movements and paid market-data activation are outside this preview.
