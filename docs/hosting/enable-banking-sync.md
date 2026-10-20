# Enable Banking sync pacing

Connections share a persisted budget by family, Enable Banking application and
exact ASPSP name/country, so reconnecting a consent does not reset its bank
cooldown. Background refreshes run at most once every six hours; a manual refresh
can run after the connection's 15-minute minimum interval, unless a bank's hard
rate-limit deadline is still active. A PostgreSQL advisory lock prevents
overlapping imports for that bank scope. Data requests are spaced by about one
second per bank, including pagination and date-window fallback requests.

Only a fresh, user-triggered fetch may send the current request's PSU IP and
user-agent, and it sends them only when all headers required by the ASPSP are
available. Background jobs send no PSU headers. The previous request IP is not
reused. The interactive context is short-lived, encrypted in the queued sync,
bound to its item, session and user, and consumed once.

Before any bank account is linked, the consent callback records the account
catalog and marks accounts for setup without consuming a data-refresh cycle.
Completing setup or linking an account starts the first eligible data refresh
from that user request.

HTTP 429 and the structured `ASPSP_RATE_LIMIT_EXCEEDED` error immediately stop
the import, including the remaining accounts, transaction pages and pending-data
requests. Sure retains the last saved financial data and the bank authorization.
The attempt records a deferred status rather than a generic sync error.
Scheduling a retry does not advance the last successful data refresh time.

A valid `Retry-After` header supplies the next hard rate-limit deadline, with a
15-minute minimum. It is shared across connections for the same bank scope.
Both delta seconds and HTTP dates are supported. Invalid, expired or excessively
long values (over seven days) use the fallback: six hours, then twelve hours,
then at most daily until a refresh succeeds. These are conservative application
defaults, not a statement of any particular bank's contractual quota. Temporary
network failures and HTTP 5xx responses allow three retry attempts, with nominal
5-, 15- and 60-minute delays. The effective automatic deadline also respects the
item floor, six-hour background cadence and any shared hard bank limit. Exhausted
retries surface as an ordinary failure requiring investigation.

Retry intent is stored in PostgreSQL and a delayed job runs it at the effective
automatic deadline, including the background cadence and any shared hard limit.
The existing hourly scheduler also recovers overdue retries if queueing failed
or a job was lost. Obsolete retry jobs cannot bypass a newer deadline.
Reauthorization and disconnecting a consent do not clear the persistent bank
budget. Invalid authorization prevents background retry requests.

Bank Sync distinguishes normal background pacing, an active hard rate limit and
an automatic retry, showing the next relevant time with the local time zone.
Partial imports do not advance the last successful refresh time. Support
diagnostics record retry reason, HTTP status, attempt and deadline without
response bodies, financial data or credentials.

Older successful timestamps are conservatively inferred from completed syncs
that reached post-import account setup. Deferred and explicitly partial attempts
are excluded. Historical records cannot establish whether every older balance
request succeeded; new imports record that distinction explicitly.

## Balance snapshots and support diagnostics

The displayed balance is the latest successfully saved provider snapshot;
“last fetched” records when Sure last fetched provider data, not the balance's
statement or effective date. Recent successful balance selections appear in the
super-admin Debug view (`/settings/debug`) with sanitized candidate types,
amounts, currencies and dates, plus the selected amount and fetch time. These
diagnostics contain financial balance amounts.

## Reconnecting without duplicating accounts

Enable Banking's API account UID belongs to a consent session. Sure remembers a
separate account identity: a SHA-256 fingerprint of the primary
`identification_hash`, bank name, country and currency. The fingerprint stays on
the native Sure account when its provider link or connection is removed. The
bank name is also retained for sidebar grouping after disconnecting.

Both account-setup actions use `EnableBankingAccount::Linker`. Legacy connected
accounts without a saved fingerprint are matched only by the same primary bank
identity, and ambiguous matches require explicit repair. A later consent
with the same identity reuses the original Sure account and its entries,
annotations and transfer relationships. It replaces the provider link rather
than creating another account. Setup is transactional and repeated submission
is idempotent. Accounts in different currencies stay separate even when they
share an IBAN. Reconnecting a disabled account preserves its disabled state.

Reuse requires owner or full-control access and a compatible account type,
subtype and currency. An existing connection to a different provider or an
account pending deletion prevents reuse. Without the primary hash, Sure does
not guess an identity from a name, IBAN, balance or secondary hash. See the
[Enable Banking account reference](https://enablebanking.com/docs/api/reference/).

## Repairing older duplicates

`EnableBankingItem::DuplicateRepair` is an operator-only reconciliation service.
It requires explicit canonical/duplicate/provider account IDs for each pair;
it does not discover or merge accounts heuristically. Its default call is a
dry run. Apply only during a maintenance window with imports and user writes
paused, and hold the connection's `with_sync_lock` while applying.

The service validates the entire plan before writing. It retains original
account and transaction IDs, preserves newer compatible valuations, remaps
cross-account transfers and removes only unconfirmed matches that would become
self-transfers after consolidation. Unexpected user changes, relationships,
conflicting valuations or incompatible records abort the transaction. Deleting
an account directly is not a substitute: normal deletion also removes its
transfer relationships.
