# CA Auto Bank deposits

This self-hosted preview connects an Italian Conto Deposito Libero and its active
Tempo deposits through the bank's existing web authentication and read APIs.
Enable preview features for an administrator, then open **Settings → Bank sync →
CA Auto Bank → Connect**. The same connector is available when adding a Savings
account. Active Record encryption must be configured before credentials are sent.

## Login and session lifetime

Enter the bank email and password in Sure, then approve access in the My CA Auto
Bank mobile app. Sure checks the existing approval every ten seconds, for at most
five minutes and thirty checks, then queues the first deposit snapshot. The manual
**Check approval** fallback is hidden while automatic checking is running and
remains available if JavaScript cannot run or checking fails. The password is never persisted.
Only the encrypted approval state and accepted bank session are retained.
Transient bank or malformed-response errors retry within the same bounded
approval window. After approval yields a token, Sure retains it only in encrypted
pending state until the bank identity has been verified; a retry does not redeem
the approval again. Cancellation, expiry and terminal authentication errors clear
that pending credential. The prior accepted connection is unchanged until identity
verification succeeds.

Failed login steps produce a support diagnostic with a fixed operation name,
HTTP status, numeric bank error code when available, and transport exception
class. Passwords, tokens, cookies, response bodies and profile data are excluded.

This release supports SmartCode/app approval. SMS authentication and additional
partner-selection login branches are not implemented. It needs no browser,
screen-sharing server, extra container, API subscription or Enable Banking setup.

Automatic renewal is not implemented. The observed bank JWT declared a
3,600-second lifetime. On 18 October 2026 it was accepted at 17:22:24 UTC and
rejected with HTTP 401 at 17:23:18 UTC, after its declared 17:23:06 expiry. Recent
read activity therefore did not extend that session. No refresh credential or
routine refresh flow was found in the inspected production client.

Sure syncs on connection and through the owner's explicit **Sync now** action.
This preview does not participate in scheduled or bulk family syncs. Sure asks
for reconnection when its session expires. Bank authentication rejection also invalidates the saved
session. Saved accounts, balances and deposit details remain available. No
password retry, OTP request or speculative keepalive runs in the background.

## Accounts and values

- **Libero:** an EUR Savings account using the bank's available cash balance.
- **Each active Tempo deposit:** a separate EUR CD account using principal only.
  The detail page shows its reported rate, start and maturity dates, and contract
  interest. Interest is displayed as reported, without classifying it as paid
  income or adding it to principal.

All accounts use the CA Auto Bank institution and participate in Sure's existing
bank folders, net worth and account visibility rules. There is no additional
aggregate account: Libero and the individual principals already make up the
tracked deposit value.

The importer validates the entire response before writing. Fixed principals and
net-return summaries must reconcile with the bank's overview; processed deposits
must match their contract details. Duplicate identities, malformed amounts,
missing report scopes, stale sessions and older snapshots preserve the preceding
data. Accounts are updated atomically. A formerly active deposit absent from a
complete reconciled active-deposit response receives a zero current principal;
its account and prior history are kept. That state does not identify whether it
matured or was withdrawn early.

Balances are snapshots from the first successful synchronization. Movement and
interest-payment history are not imported yet: their balance semantics, history
completeness and duplicate identity need further verification. Current balance
anchors must not be represented as historical interest income.

## Ownership and disconnection

Each connection belongs to its initiating Sure user and family. Connecting,
polling, canceling, syncing and disconnecting require a self-hosted administrator
with preview access. Pending approval is also bound to the initiating Sure
session. Impersonated sessions cannot manage the connection. Changing bank
identity during reconnection is rejected.

Disconnecting clears the bank session and pending approval, invalidates in-flight
snapshots, and keeps saved accounts. A generic account unlink is respected: the
importer does not silently recreate its link. Such a conflicting connection
requires review before a complete subsequent snapshot can be applied.

The provider uses one fixed HTTPS origin, explicit request routes, verified TLS,
bounded response sizes, and request timeouts. It exposes no transfer, deposit
creation, early-withdrawal or trading operation. The ordinary web session itself
has not been established to carry read-only bank permissions.

## Verified read routes

The base is `https://www.clienti.ca-autobank.it`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/mybank-service/authentication/api/v1/user` | Verify authenticated bank identity |
| GET | `/mybank-service/term-deposit/api/v1/deposit-accounts` | Enumerate owned report scopes |
| GET | `/mybank-service/term-deposit/api/v1/deposit-accounts/contracts` | Match account contracts |
| POST | `/mybank-service/term-deposit/api/v1/deposit-accounts/overview` | Read cash and restricted-principal totals |
| POST | `/mybank-service/term-deposit/api/v1/deposit-accounts/time-deposits/processed` | Read active deposits |
| POST | `/mybank-service/term-deposit/api/v1/deposit-accounts/time-deposits/details` | Read individual contract details |

The processed query uses the observed 2015-to-today window and active-status
filter. Overview reconciliation is required, so an omitted principal cannot be
silently accepted. Report identity uses service, branch and account number;
deposit identity is scoped to that report and its bank operation number. That
number's stability across future bank sessions is an integration assumption,
not a verified public API guarantee.
