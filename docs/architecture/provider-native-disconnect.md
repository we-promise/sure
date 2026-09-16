# Disconnecting a native connection from Sure

Status: shared command, browser review and behavioral tests are written but unrun.
Ruby/Bundler are unavailable in this workspace. No connection has been disconnected,
no migration executed and no additional adapter enabled.

## Local disconnection and source ownership

[`ProviderConnection::Disconnect`](../../app/models/provider_connection/disconnect.rb)
stops synchronization and removes the selected connection's links across its
financial accounts in one transaction. It keeps those Accounts, Entries, Holdings,
source observations, financial evidence, Sync history, batches, checkpoints,
authorizations, encrypted credentials and original migration archives. It does not
destroy the connection, revoke remote consent, erase secrets or disconnect another
provider attached to the same Account.

The browser calls this **Disconnect from Sure** and states the distinction from
revoking bank/provider access. GET reviews the affected account names; POST accepts
only the review token. An active family administrator must also have owner or
full-control access to every affected financial account. A private account is not
made manageable merely by sharing the administrator's family. Denial is atomic.

The command uses the same native-readiness and migration ownership admission as
shared settings. The implementation is shared across adapter families, but their
existing readiness gates and cutover acceptance requirements still apply. Up is
the only currently opted-in adapter; this change does not enable the other 22 or
make their legacy deferred work safe to cut over.

## Review, locking and commit

The command acquires the credential session lock before any transaction, without
opening a refresh Session or changing uncertain credential state. Its
[`Links`](../../app/models/provider_connection/disconnect/links.rb) admission then
captures every affected account's complete source graph and acquires all required
legacy lifecycle permits before starting one transaction. Ordered nonblocking
locks cover connections, migration controls, financial accounts, live or retained
source owners, external accounts, mappings, links, users, shares, policies and
affected routing references. The graph is captured again under those locks.
Original mapped and live legacy children are also checked for links or direct
foreign keys that are missing their shared counterpart; they cannot disappear
from the inventory merely by losing an external-account pointer.

The 30-minute signed review pins the actor, connection, management revisions and
a digest of that graph. Changed links, source selections or permissions require
a new review. Admission is bounded to 100 financial accounts, 10,000 rows per
enumerated collection and a 4 MiB serialized graph; these are refusal limits,
not evidence of performance acceptance for large portfolios.

Incomplete Account or involved native connection Syncs, any native lease including
an expired one, and unfinished generations prevent disconnection. The selected
connection also refuses migration leases, incomplete original legacy Syncs and
unsettled credential claims. A failed Sync does not settle its still-fetching or
sealed generation. Existing provider cutover gates must separately settle legacy
jobs that run outside the ordinary Sync lifecycle.

Only the selected connection's policies are deactivated. Their immutable revisions
and original source tuples remain. Only its AccountProvider links, corresponding
Holding routing references, matching direct Plaid/SimpleFIN FKs and selected
Account::SyncSource pointers are detached. Other providers' links, policies and
calculation pointers remain unchanged. Sealed calculation inputs are history and
are never rewritten. Native tracking-row destruction callbacks do not run.

Disconnection sets the connection to `disabled`, advances its writer epoch and
stores a signed completion receipt in connection metadata in that same transaction.
Current request grants become stale. Native scheduling and credential admission
reject the disabled owner. Migration control remains native-owned, so this local
operation does not restore a legacy writer.

[`Account::Linkable#provider`](../../app/models/account/linkable.rb) now uses the
first-link compatibility fallback only when no balance-policy history exists.
Deactivating a previously selected source cannot silently choose another provider.
Remaining physical links still make the account linked; this operation does not
change calculation direction or reconcile a future source handover.

## Retrying a completed request

The receipt uses the existing retained identity-signing keyring and binds the exact
submitted token, actor, original graph digest, connection identity and resulting
writer/credential revisions and migration ownership. An identical submission can
return its already-committed result after the browser token expires. It performs
no second detachment, epoch change, queue operation or upstream request.

Replay requires a current active administrator in the original family, a valid
receipt, the same disabled result and no live account links. It starts through
explicit disabled management admission instead of requiring the now-removed links.
A database-only check covers shared links and the original mapped/live legacy
references, including direct Plaid/SimpleFIN FKs, without decoding old archives or
acquiring a legacy permit inside the replay transaction.
A disabled row without this command's receipt, a different actor/token, altered
receipt, changed result or newly attached link is refused. Normal settings and
account setup continue to reject disabled connections. A completion marker cannot
be reused as a reconnect operation.

## Acceptance and remaining lifecycle work

Authored tests cover preservation across multiple accounts/providers, source
authority, permissions and stale review, busy work, credential-session exclusion,
transaction rollback, signed receipt replay and controller boundaries. The UI uses
existing design-system primitives. Static checks do not replace Rails behavior,
database concurrency or browser verification; all remain unexecuted here.

Upstream consent revocation and its retry semantics, reconnecting a stopped
connection, individual-source selection controls, credential erasure/retention,
full-family deletion and acceptance of every provider's native cutover remain
separate requirements. Do not invoke legacy `destroy` callbacks to supply remote
revocation: they may also delete retained Sync/source history. See the
[retirement inventory](provider-retirement-inventory.md),
[account unlink contract](provider-native-account-unlink.md) and
[implementation status](provider-implementation-status.md).
