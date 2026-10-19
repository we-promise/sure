# Enable Banking sync pacing

Each bank connection has a persisted refresh deadline. Manual refreshes, login
refreshes and family jobs share the same 15-minute minimum interval. A PostgreSQL
advisory lock prevents overlapping imports for the same connection, including
imports that outlast that interval. Other banks can continue syncing independently.

HTTP 429 and the structured `ASPSP_RATE_LIMIT_EXCEEDED` error immediately stop
the import, including the remaining accounts, transaction pages and pending-data
requests. Sure retains the last saved financial data and the bank authorization.
The failed sync stays failed: scheduling a retry does not advance the last
successful refresh time.

A valid `Retry-After` header supplies the next attempt, with a 15-minute minimum.
Both delta seconds and HTTP dates are supported. Invalid, expired or excessively
long values (over seven days) use the fallback: six hours, then twelve hours,
then at most daily until a refresh succeeds. These are conservative application
defaults, not a statement of any particular bank's contractual quota. Temporary
network failures and HTTP 5xx responses get three retries after 5, 15 and 60
minutes, then surface as an ordinary failure requiring investigation.

Retry intent is stored in PostgreSQL and a delayed job runs it. The existing
hourly scheduler also recovers overdue retries if queueing failed or a job was
lost. Obsolete retry jobs cannot bypass a newer deadline. Successful refreshes
clear the retry state; reauthorization clears the previous consent's cooldown.
Disconnecting or an invalid authorization prevents background retry requests.

Bank Sync shows a warning with the planned retry time and disables repeated
refresh clicks during cooldown. Permanent errors and unrelated failed
connections remain errors. Support diagnostics record retry reason, HTTP status,
attempt and deadline without response bodies, financial data or credentials.

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
