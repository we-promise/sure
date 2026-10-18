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
