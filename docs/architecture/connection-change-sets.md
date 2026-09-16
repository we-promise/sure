# Connection-wide transaction and activity change sets

Status: the immutable group contract, encrypted codec, complete-generation
assembler and durable transaction runner are implemented but unverified.
`ProviderSyncGeneration` records capture/seal/application state; encrypted batches
retain provisional pages and bounded account changes. Plaid selects this runner
through `transaction_scope == :connection`; Trade Republic selects its activity
resource through `activity_scope == :connection`. Native activation remains gated on
executable crash/concurrency checks, legacy identity/cursor transfer, newly linked
account replay and the other provider requirements in the implementation status.

Some APIs paginate an account's history. Others paginate a connection-wide change
log spanning several institutions and accounts. Both produce the same financial
records, but their checkpoint scopes and commit boundaries differ. Scope must be
part of the adapter contract; a connection cursor cannot become an account cursor.

## Capture before financial application

Each generation records an immutable ID, original committed cursor and requested
cursor for every response. Capture the provider's bounded response and normalized
account pages, including unlinked accounts, in encrypted evidence. The original
cursor remains authoritative until the complete generation has been applied.

No financial writes occur while the generation is still being fetched. A
transaction continuation failure or a provider mutation-during-pagination signal abandons the
provisional generation and starts a new one from the original committed cursor.
Abandoned pages remain diagnostic evidence; they cannot be reused as a successful
prefix or authorize removals. Retries and repeated cursors have finite limits.
Declared resumable activity adapters instead retain their bounded prefix for the
same logical Sync. A different Sync cannot adopt unfinished activity work.

When the terminal page has been captured, seal the generation. Resolve each account
identity within the same connection. Fold successive changes for the same upstream
transaction according to the provider's ordered change-log contract. A record
cannot be both posted and removed in the resulting account change set.
The captured `folding_policy` is immutable across the generation. Plaid's initial
port retains its legacy modified-then-added ordering across all pages, followed
by all removals; it does not silently adopt page-chronological precedence.
Activity groups use explicit first-observation precedence and prohibit removals
or absence authority. Trade Republic additionally verifies duplicate event routing
across its two topics before applying that precedence.

An unassigned removal can be routed only through an unambiguous source identity
from this connection. A matching name, institution, amount or date cannot establish
ownership. Ambiguous removals stop promotion and require reconciliation. Unknown
removals with no financial posting may be retained as tombstones; existing legacy
postings need their migration evidence before automated deletion is permitted.

## Fanout and promotion

Materialize bounded child batches with immutable links to the sealed generation.
Each child retains the account's captured source-policy revision. Each financial
write rechecks current tenancy, linkage, connection ownership and source authority.
Ledger changes, source evidence and the child applied marker commit atomically.
Retries resume applied children without repeating their financial effects.

Only after every required child is applied may the connection checkpoint advance
to the generation's terminal cursor. Cursor promotion and the generation's complete
marker commit together. A crash before promotion resumes this same sealed generation;
it does not fetch another generation or discard outstanding children.

Unlinked accounts retain captured observations without financial publication.
Linking later requires an explicit replay/backfill boundary, because the connection
cursor may already have advanced past those observations. A failure in one account
cannot silently mark the shared change log complete. Partial account application
is visible in generation status even though the committed cursor has not advanced.

For transaction generations, the current runner marks an external account's `transaction_backfill_required`
column when changes are retained without publication. Linking that account cannot
start another generation until replay has been resolved. The flag is operational
state, separate from provider-supplied metadata. The replay command and its setup
workflow remain to be implemented; clearing the flag alone is not a backfill.
Activity generations retain unlinked observations too. Trade Republic currently
rescans both topics for each new generation; efficient replay of retained activity
history and any incremental newest-event shortcut still require explicit handoff.

Retained changes also maintain unbound `SourceRecord` identities, allowing a later
account-less tombstone to resolve within the same connection. They cannot acquire
Entry/HoldingSource links while the financial account binding is null. First
publication uses the current link and a newly captured source-policy batch; once
bound, that target cannot change. Retaining new data for an already bound source
does not alter its published evidence or ledger while the account is inactive.

Capture is bounded to 500 provider pages, 100,000 changes and 64 MiB decoded /
96 MiB stored group input; adapters may impose smaller limits. Sealing produces
account commands of at most 1,000 records/removals each. Their complete flag covers
only their explicit identities; it never authorizes absence pruning. Source-policy
revisions, account links, visibility and authorization state are captured before
fetching and rechecked at publication. Unknown account identities and unresolved
removals stop promotion. A provider mutation can restart twice within one run;
ordinary transaction fetch failures leave an abandoned encrypted prefix for
diagnostics. Resumable activity groups retain their prefix and defer after a
bounded request budget, without promoting the connection checkpoint.

The initial connection-grant fence includes external connection identity, region,
environment and credential revision. It is deliberately conservative for Plaid's
direct-token cursor. Resumable activity groups instead verify every credential
transition through a contiguous chain of captured request grants while preserving
the original consent, membership and source context. Durable session-rotation
receipts now retain the credential transition even when the following group
capture fails. An admitted same-Sync retry must verify that exact receipt chain;
missing proof still refuses resume. Receipts do not reopen failed jobs or recover
workers left in progress, and executable recovery acceptance remains required.
Connection credential changes through
ordinary model writes advance their revision, as do the shared credential-store
methods. See [request grants](provider-request-grants.md) and the
[Trade Republic timeline protocol](trade-republic-native-port.md).

The additive activity-generation migration pins each page, account child and
checkpoint to its generation's resource using composite foreign keys. A
transaction generation cannot acquire an activity child. Existing transaction
groups retain their default resource and folding behavior. Database constraints
and regression tests remain unexecuted in this workspace.

For APIs offering account-scoped cursors as an alternative, switching scope is an
explicit migration: begin independent account cursors from their documented initial
state and reconcile existing stable identities. Never initialize them from an old
connection cursor. This is a different rollout choice from preserving the existing
connection-wide stream.

## Acceptance scenarios

- Mutation after the first captured page produces no provisional financial writes;
  the replacement generation begins at the same committed cursor.
- Crashes after capture, after any child commit and immediately before cursor
  promotion resume deterministically without duplicate entries or skipped accounts.
- Secondary providers and unlinked accounts retain evidence without independently
  posting transactions already owned by another source.
- Explicit removals preserve user changes and other live source evidence, and
  preserve the removed Entry UUID in historical provenance.
- A changed policy, account link, grant or writer epoch prevents stale application.
- Switching cursor scope, newly linking an account and unknown removal routing have
  explicit tested backfill/reconciliation behavior.

The [implementation status](provider-implementation-status.md) and
[migration matrix](bank-data-provider-migration-matrix.md) remain the acceptance
record. A native reader alone does not establish this commit protocol.
