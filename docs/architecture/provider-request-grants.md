# Request grant capture and publication

Status: implementation and behavioral tests are written but unrun. This does not
activate additional providers or perform migration/cutover.

An account binding answers which financial account and source policy may receive
a page. `Provider::AccountData::RequestGrant` separately pins the authorization
that actually constructed its adapter. Capturing today's authorization revision
after building a client with yesterday's credentials would not prove that link.

`Registry.build(..., request_grant:)` captures and holds the connection,
authorization and membership rows while reading factory credentials and runtime
context. Factories construct clients without HTTP. The snapshot contains
connection/family/provider identity, region, environment, credential revision and
eligibility state, plus authorization identity/revision/status/expiry and
membership identity/revision/status. It contains no connection credentials or
credential hashes. Normalization input evidence uses keyed fingerprints as
described below.
The inventory is bounded to 10,000 authorizations and 20,000 memberships.

Before each ordinary request, Syncer verifies the adapter's original snapshot,
in addition to capturing the account's source binding. Any intervening consent,
membership, connection identity or credential change rejects the request. A grant
that expires without a database update also fails verification. Capturing again
cannot replace an existing stale snapshot.

Responses carry runtime-owned `request_grant` evidence inside their encrypted
canonical page payload. It records the pre-request state, the state accepted for
publication and explicit credential transitions during that request. Provider
responses cannot supply this reserved evidence key, including on grouped account
pages. Source bindings and captured payloads remain immutable.

Publication verifies this evidence under the connection fence before changing
external account data or invoking the ledger writer. A grant change during HTTP
can therefore leave a captured response for diagnosis while rejecting publication
and checkpoint advancement. An unapplied older page without request-grant evidence
requires a reviewed restart; it cannot acquire a new authorization at replay.
Already-applied pages do not repeat financial writes.

The connection-wide TransactionSync path receives the same construction grant,
checks it before fetching, stores it in the generation's immutable context and
captures evidence on every group page. Sealing verifies those page grants against
the generation, and child publication and cursor promotion recheck the captured
grant. A generation cannot refresh its context from a newly constructed adapter
when a worker resumes it.

## Intentional credential rotation

RuntimeContext passes the same grant capability into CredentialStore. Its sessions
can access credentials only inside that execution's active request. A successful
refresh-token or session-cookie save can advance the in-memory expected revision
by exactly one, after the store's existing ownership check and durable save. The
remaining connection identity, consent and membership snapshot must still match.
The request records each accepted transition, up to 64 per request. Re-saving an
unchanged cookie jar adds no transition.

Another credential-store instance, an administrative credential replacement or a
changed consent cannot create an accepted transition for an existing request.
Interrupted refreshes retain the existing uncertain-intent/reauthorization rules.
CredentialStore calls are outside HTTP-spanning database transactions; only their
short persistence operations acquire connection/grant locks. After the request
ends, its bound store cannot lend credentials to another execution.

Plaid's connection-wide transaction path retains its direct-grant contract and
rejects rotation during a generation. Declared resumable activity groups now have
an explicit transition contract: every captured request must form a contiguous
chain from the generation's original grant to the current database grant. The
chain retains all non-credential authorization fields and permits only the
credential revisions proved by those requests. A resumed factory may recapture
its execution clock; all other runtime-input fingerprints must agree. Captured
activity observations retain their original time and normalization context.

Resumable activity requests now additionally retain a `ProviderCredentialReceipt`
for each confirmed ordinary session rotation. The receipt and replacement cookie
commit in the same connection transaction. A failed receipt rolls back the
credential write; a failed outer commit invalidates any speculative in-memory
grant. No-op cookie saves add no receipt. Single-use refresh intents keep their
existing uncertainty/reauthorization behavior and cannot use this session-only
recovery protocol.

Each receipt pins the family, connection, original Sync/generation, current request
position, preceding captured page, attempt UUID/ordinal, admitted lease owner/epoch,
and exact credential revision transition. Encrypted keyed fingerprints bind the
authorization/normalization context and the captured prefix; cookie values are not
copied into receipts. Both receipt writes and subsequent credential access recheck
the live lease, cancellation state and unchanged fetching position. Database
constraints pin generation/Sync ownership, require an activity generation and the
exact preceding page, and prohibit receipt updates.

Version 2 request-grant captures retain exact receipt IDs for their own rotations
and any recovered failed attempts. Only the current uncaptured page may discover
receipts in its exact scope and revision range. Completed pages must verify their
explicit IDs in order. Missing, foreign or non-contiguous proof refuses adoption
of the current credential revision. A failed read's receipts advance credential
lineage only: they contain no transactions and cannot complete a page or advance a
checkpoint. The next admitted read repeats the uncommitted group using the proved
credentials. Version 1 direct-grant requests, including Plaid, retain their prior
contract.

The bounds are 64 rotations per request, 256 receipts per page, 32,000 receipts per
generation and 4 KiB stored evidence per receipt. Prefix loading also uses the
generation byte bounds. Receipts remain attached to their generation/prefix with
no independent expiration policy; rollback refuses while receipts remain. Key
rotation and retention/disposition still require deployment acceptance.

Proof continuity is separate from job liveness. The coordinator can safely verify
a separately admitted retry in the same logical Sync, and completed discovery for
that exact Sync is reused regardless of its retry counter. An ordinary error still
terminalizes a Sync, and an interrupted worker can leave it in progress; these
receipts do not reopen either state. Recovery/abandonment of those executions and
the full crash/concurrency tests remain activation gates. See the
[Trade Republic timeline protocol](trade-republic-native-port.md).

Rotating credentials on ProviderAuthorization rather than ProviderConnection also
needs a typed store contract; neither authorization nor membership revisions are
silently advanced by the connection credential callback. Deployment-wide fallback
and application credentials are captured as exact-value keyed fingerprints;
changing them rejects an older adapter's request or publication.

## Runtime boundaries and remaining checks

Syncer and TransactionSync own request verification and publication checks.
LedgerWriter continues to require the separately captured account binding and
source-policy checks. A future caller that bypasses those coordinators must also
verify request-grant evidence, or use its own explicit non-provider publication
contract; constructing a LedgerWriter is not a credential authorization API.
Registry binds the original RequestGrant to the adapter it constructs. Passing
that adapter into Syncer or TransactionSync retains this grant; an explicit
replacement is rejected. Pure adapters injected without Registry remain a trusted
testing seam. All production adapter construction uses Registry.

### Declared normalization inputs

`Provider::AccountData::RuntimeInputs` now captures and revalidates the actual
factory context. Adapters declare `external_account_inputs` with `mutable` and
`frozen` dotted paths plus an `inventory` choice (`linked` or `all`). Undeclared
external fields are omitted from the factory context. Linked-account UUID,
currency, delegated type/UUID, AccountProvider UUID/revision, ExternalAccount UUID
and namespace, upstream ID and authorization membership are always live inputs.
The adapter cannot validate stale linked currency using a newer page binding.

| Adapter | Mutable inputs beyond account identity | Deliberately frozen baseline |
| --- | --- | --- |
| Coinbase | Linked fiat currency | None |
| Trade Republic | Linked cash-account membership | None |
| CoinStats | Currency and reviewed source descriptor; complete selected inventory | Name |
| Onchain Wallet | Currency and reviewed source descriptor; complete selected inventory | Sealed wallet/quote snapshots and name |
| Indexa Capital | Currency | Retained total/cash fallback balances |
| Binance | Linked identity | Retained portfolio continuation data |
| Enable Banking | Currency, source details, account policy settings and identity aliases | Name/type fallback and merchant-name inventory |
| Sophtron | Source details and manual-sync policy | None |
| Monobank | Selected account history start | Retained checkpoints |
| Kraken / SnapTrade | Linked identity / cached currency | Name / none |
| SimpleFIN | Account identity/type and effective classifier settings | History aggregates and sticky hints |
| IBKR | Family/timezone and grant/configuration | Scoped export archive |

All adapters also pin the effective family currency/timezone/locale, connection
settings, declared deployment options, pending preference/override and any declared
connection details or application/fallback credentials. Regexp options preserve
their type in the fingerprint. Process configuration is compared by effective
value; changing a value and restoring the exact same value is not an event log.

Capture and verification lock connection, the provider Sync with `FOR SHARE`
when executing a Sync, family preferences with `FOR NO KEY UPDATE`, then the complete financial
account union in UUID order, ExternalAccounts, AccountProviders and grant rows.
A short PostgreSQL SHARE lock on the settings table also protects defaults whose
rows do not yet exist. The pending preference reads its row uncached and uses the
gem's declared field coercion/default methods; dynamic policy settings are read
uncached as well. A different worker's cache invalidation cannot leave an old
request-local preference authorizing a write. The [locked gem's field reader](https://raw.githubusercontent.com/huacnlee/rails-settings-cached/v2.9.6/lib/rails-settings/fields/base.rb)
defines the preserved stored-value/default behavior.
These locks end before HTTP; publication's outer transaction
retains them through its financial writes. A changed link while acquiring the
lock plan rejects the request rather than extending the plan. Real concurrency
tests must verify lock compatibility before activation.

The retained-source collectors and clock inputs are fingerprinted at construction.
Verification does not
rebuild history, checkpoints, archives or merchant names. Expected cache, balance
and inventory-name updates therefore do not replace a frozen baseline or reject
every next page. New unlinked inventory rows are allowed for `linked` declarations;
new links and any selection change for `all` declarations require a new execution.
A routing or policy edit, including one first learned during inventory, similarly
requires a reviewed restart if it changes an input cached by the existing adapter.
The contract does not silently rebuild or advance that context.

Evidence indexes accounts by exact UUID and records their namespaces. Current
adapters that still look up cached rows by upstream ID reject duplicate IDs across
namespaces before factory construction. SimpleFIN's production snapshot now
selects by UUID and checks namespace; the unscoped shape is restricted to explicit
pure-adapter fixtures. Retained history keeps the existing collector's query
semantics and fixed execution clock; this is not a database time-travel snapshot.

Captures allow at most 10,000 external accounts and 96 MiB of their stored metadata
and encrypted details, checked before loading those documents. Each typed input
fingerprint also has a 96 MiB serialized bound, one million nodes and depth 32.
Existing archive-specific bounds continue to apply. Errors expose no input values.

Fingerprints use HMAC-SHA256 with a key derived by Rails' key generator using the
purpose `provider-runtime-inputs/v1`. Neither values nor an unkeyed secret digest
are written into evidence. The key has the lifetime of the application's key
generator secret (normally `secret_key_base`). Rotating that secret invalidates old
input proofs: unapplied pages need a reviewed restart, not automatic rebinding.
Already-applied evidence remains retained. Provider-supplied evidence cannot
replace runtime-owned proofs. Older production pages lacking input proof also
fail closed; direct LedgerWriter callers still need their own publication contract.

### Per-request account and window proof

`RequestInputs` separately attests the exact canonical account Record passed to
each ordinary `fetch_*` call. That includes Enable Banking's API account ID and
authorization selector, Brex's card/cash account kind and currency fallback, Up's
currency fallback, and SimpleFIN's account type/currency. These are request-local
inputs even when the factory retains a different, deliberately frozen baseline.
The entire typed Record is fingerprinted, including private routing metadata;
the evidence exposes none of those values.

Syncer selects its initial window and checkpoint, then admits each request through
the original RequestGrant. Under the grant's full ordered lock plan, admission
captures the account binding and fresh canonical Record and verifies that the
configuration and checkpoint which selected the window/cursor are still current.
It does not quietly change the window to accommodate an intervening edit. HTTP
receives immutable copies of the admitted window/cursor and the canonical Record.
The provider Sync lock precedes financial Accounts, following Account sync queue
and handoff ordering; SHARE pins mutable window fields while allowing KEY SHARE
reads. All admission locks end before HTTP.

Runtime-owned `request_inputs` evidence is scoped to connection/family, Sync,
stream, ExternalAccount UUID/namespace and the page's idempotency key. Its keyed
fingerprints cover the exact Record, account binding, selected window/cursor,
window configuration and full checkpoint state, including cursor and revision.
It uses purpose `provider-request-inputs/v1` with the same key lifetime and typed
byte/node/depth bounds as RuntimeInputs. Providers cannot supply this reserved key,
including inside grouped responses. Batch payloads and bindings remain immutable.

Publication first revalidates RequestGrant, then the request proof under retained
locks, before any external-account cache or ledger writes. Routing, currency,
metadata, configured date bounds, checkpoint replacement and namespace/link edits
during HTTP leave captured evidence and reject publication. An absent checkpoint
is also pinned by the connection fence; ordinary checkpoint writers use that same
fence. Writes that bypass the connection contract are unsupported. A page without
this proof requires a reviewed restart. Already-applied pages do not write again.

After its own page commits, the stream may continue from that checkpoint and the
previous immutable response's cursor/coverage; the next page captures a new Record
to reflect those expected cache updates. Factory-retained history remains frozen
throughout. Window/cursor fingerprints attest the exact admitted values rather
than recomputing old page selections from today's checkpoint during replay. The
configuration, checkpoint and Record are still checked against current state
before an unapplied page can publish. Connection-wide TransactionSync continues
using its separate generation/cursor/account-binding contract because its fetch
does not receive an ordinary account Record or date window.

The correctness-first factory proof currently rereads and locks the complete
declared account union for each account request. Across N account streams that is
O(N²) account work, plus shared settings/family lock contention. Byte/count bounds
limit individual captures, not total run cost. Realistic inventory benchmarks and
lock-contention tests remain activation gates; a future revision-counter or
scoped-input optimization must preserve these checks. Growth/performance is not
validated by the unrun tests or this implementation.

Balance responses update the exact supplied ExternalAccount UUID and namespace.
Inventory discovery still declares the connection namespace; an inventory balance
with the same external ID cannot authorize another namespace's cached balance.

An otherwise eligible connection with an active lease defers before constructing
an adapter or credentials. Retry is bounded by the earlier of the lease expiry and
15 seconds, preserving the successor execution instead of failing it permanently.
Ownership and eligibility failures remain stale-writer errors.

Production grants also bind the immutable live `SyncExecution` capability before
adapter construction. Every request admission, credential access and credential
rotation checks its lease owner, writer epoch, execution revision and freshly
locked Sync/cancellation state. That capability is separate from replayable grant
evidence: a replacement worker can verify retained captures, but an old grant
cannot rebind to the replacement execution. Ordinary cookie writes, including
unchanged jars without generation receipts, must pass this check. These guards
run under Connection → Sync locks and end before network I/O. See
[execution recovery](provider-sync-continuations.md#interrupted-executions-and-finalization)
for the job-level boundary and outstanding acceptance requirements.

Run the grant, credential-store, ordinary Syncer and TransactionSync behavioral
tests in Rails/PostgreSQL, including real concurrent revocation and refresh races,
before activating these paths. Tests have not run in the current Windows workspace.
