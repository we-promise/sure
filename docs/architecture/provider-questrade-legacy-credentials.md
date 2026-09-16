# Questrade legacy credential sessions

The legacy Questrade consumers now use an operation-scoped credential session.
The implementation and focused behavioral tests are written but unrun in this
environment. Questrade native readiness remains false; this is not a complete
credential migration. The follow-on [durable activity request protocol](provider-questrade-activity-requests.md)
now owns deferred dispatch and recovery.

Previously `QuestradeItem::Provided` returned a credential-bound SDK whose token
exchange callback held `item.with_lock` across HTTP. Direct importer and delayed
activities-job callers could obtain this client outside the migration permit,
and the controller replaced refresh tokens without joining credential
serialization. Broad activity/import rescues could turn an ownership refusal
into an empty response, statistics update or pending-flag cleanup.

`QuestradeItem::CredentialSession` now takes the shared legacy migration permit
before a PostgreSQL session advisory lock for the original item. It retains both
through an import, full legacy Sync or deferred activities operation. Exact
same-item reentry is supported; source widening and an enclosing database
transaction are refused. Unknown lock acquisition/release outcomes disconnect
the database session, clear local context and preserve the original exception.

The session reloads and pins the item/family and credential tuple. The full Sync
path also pins its original Sync and ancestors. Every HTTP attempt, including
GET retries and forced refresh after a 401, checks current ownership before and
after the response. HTTP runs outside row transactions. Public factory consumers
receive a lazy facade pinned to the original item/family IDs, rather than an
escaping credential-bearing client. A raw SDK obtained inside a session refuses
use after that session closes. Controller credential updates join the same
permit and session lock; the existing family/admin boundary remains in place.

Before spending a refresh token, a short committed update sets the existing item
status to `requires_update`. There is exactly one POST, with transport retries
and redirects disabled. Its bounded response must contain usable replacement
tokens, expiry and an HTTPS Questrade API server. The original credential tuple
and source are rechecked before committing the replacement token/server and
restoring `good` together. Only after that commit does the SDK lend the new bearer
to a data request.

Timeout, malformed response, process interruption or failed replacement commit
leaves the durable refusal state. A later session cannot reuse the possibly
consumed token; explicit credential replacement is required. This deliberately
uses an existing status field, not a new journal or monotonic credential
revision. It does not prove recovery of a remotely consumed token or defend
arbitrary out-of-protocol SQL credential ABA. Native `CredentialStore` retains
its separate intent/revision protocol. The related native reader correction
preserves `StaleWriter`, credential busy and reauthorization denials instead of
rewrapping them as ordinary uncertain-exchange authentication errors.

The importer constructs its client only after admission, uses the freshly
scoped Sync, and propagates ownership/busy/invalid-source denials before ordinary
rescue or recovery writes. The full legacy Sync holds the same session through
cached processing and child scheduling. This exclusion prevents native handoff
from racing those credential consumers; it is not a substitute for financial
publication checks against concurrent user relinking. The follow-on
[publication admission](provider-questrade-legacy-publication.md) now covers the
direct account processors and source snapshot entrypoints.

New activities requests durably capture original item, family, provider-account/
remote IDs, financial account, AccountProvider revision and optional Sync ancestry.
Deliveries identify that receipt and its revision; retries retain the original
context and fixed date window. Old contextless deliveries refuse before transport.
An explicit completed-parent allowance preserves legacy polling. Cancellation,
failed ancestry or changed links retire only their identified receipt without
recording financial progress. Valid empty responses retain bounded polling;
exhausted unavailable responses cannot become successful empty history.

Initial job dispatch waits for the surrounding operation to release its permits.
An aborted importer therefore leaves neither a queued job nor a newly set
pending flag. Dispatch re-admits the exact original context and commits the
request before queueing. Initial and delayed queue exceptions preserve that
receipt for due-request recovery. The actual queue call occurs after session/
migration release, so an immediately starting worker can acquire its permits.

Historical `activities_fetch_pending` flags without a receipt still have unknown
ownership. The generic cleaner preserves them. After old workers are drained,
the explicit family-scoped disposition command records that unknown state as
cancelled without a successful fetch marker. Active or unknown deferred work
blocks quiescence before migration ownership changes. The encrypted request and
its revision/deadline join the lossless copy manifest. Full historical coverage,
credential transfer and lifecycle/cutover acceptance remain outstanding; see the
request protocol and publication boundary linked above.

Focused tests cover real session/migration contention, independently committed
refresh intent and replacement, one-POST timeout behavior, rollback, stale
response ownership, closed clients, original family and parent cancellation,
deferred context, immediate queue handoff, discarded callbacks, retry enqueue
failure, unavailable-versus-empty completion and obsolete delivery refusal.
Controller examples isolate the session command inside rollback fixtures;
separate real-commit model tests exercise the actual admission protocol.

## Native handover admission

`Questrade::RetainedCredentials` now joins quiesced copying, retained-copy
verification and preparation under the exclusive legacy permit. A missing,
deleting or `requires_update` legacy item cannot supply a migration-ready token.
Recovery must replace the legacy credential explicitly before a supported recopy;
an uncertain exchange is never converted into usable credentials by table transfer.

The native factory also resolves a bounded, verified retained item snapshot.
Its original good status is required even if somebody subsequently changed the
native token or revision. Missing archive proof is not reconstructed from today's
item. Runtime inputs pin the retained descriptor and provenance without exposing
refresh tokens. The copied `api_server` remains historical settings: the first
native refresh obtains its authenticated replacement server before any data read.

Nine [handover tests](../../test/models/provider/account_data/questrade/retained_credentials_test.rb)
exercise the actual copier, factory and credential store, including committed
replacement before bearer use, timeout and commit failure, stale source refusal,
and authenticated old archives containing uncertain credentials. They remain
unrun. Full native reauthorization, history/lifecycle acceptance and cutover are
still required; this guard does not activate Questrade.
