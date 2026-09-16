# Disconnecting an account from its data sources

Status: shared admission, unlink behavior and regression tests are written but
unrun. No provider has been activated and no migration has been executed.

## One account, several independent sources

[`Account::Unlink`](../../app/models/account/unlink.rb) disconnects every current
source of one financial Account, including native, migrated dual and legacy links
in the same operation. The Account remains live and retains its financial history.
The command does not revoke provider credentials, delete a shared connection or
disconnect another Account using that connection. The separate
[native connection disconnect](provider-native-disconnect.md) now reviews and
detaches one connection across all its accounts while retaining other providers.
Selecting or disconnecting one particular source for only one Account through the
UI remains separate work.

[`Access`](../../app/models/account/unlink/access.rb) captures the complete current
source graph through `Ingestion::SourceOwners`: direct Plaid/SimpleFIN references,
AccountProvider tuples, external accounts, exact migration mappings and original
legacy items. Native-only links on legacy-owned copies and missing dual mappings
are refused. Controls in `quiescing` or `rollback_pending` are refused; `active`
and `retired` retain native ownership. Missing or foreign owners cannot supply
permission to disconnect another account.

The command acquires the entire legacy-owned item permit before its savepoint.
It then locks connections and controls in UUID order, the live Account/identity,
legacy item/account rows, external accounts, mappings and provider links. Row
locks use NOWAIT. A changed graph requires restarting admission; the operation
does not expand its original source set. Current user, owner and sharing rights
are checked under locks before changes. Unknown policy bindings and holdings
belonging to another Account stop the operation.

## Data retained during unlink

Native source policies are verified against their captured original owners and
deactivated. Their revisions remain available even when ingestion batches refer
to them. Holdings lose only their live AccountProvider reference. Financial
Entries, Holding quantities and values, SourceRecords, EntrySources, HoldingSources,
archives, checkpoints, generations and provider credentials are unchanged.

Native links are removed without the legacy tracking-row callbacks. This keeps
migrated CoinStats/Onchain rows and direct SimpleFIN rows alongside their original
copy mappings. Legacy-owned sources retain their existing cleanup behavior:
CoinStats/Onchain tracking rows and direct SimpleFIN rows are deleted, ordinary
provider rows remain, and retained primary/secondary batch policy references still
prevent legacy cleanup. All link removal, policy deactivation, holding detachment
and direct-FK clearing share one rollback boundary.

The live `Account::SyncSource` pointers are cleared. Sealed child Syncs, inputs,
preparation and original source batches remain intact. A subsequent manual
calculation seals an empty provider-input set; an older queued calculation keeps
its original input and fails its stale source check instead of adopting today's
manual state. Account retirement is neither required nor performed.

## Work already in flight

Ordinary native publication rechecks the original `GenerationAccounts` binding
under Account/source locks. A page captured before unlink cannot publish using
the deleted AccountProvider UUID. Unlink does not invalidate the whole connection's
worker lease, so another account's unchanged binding can remain usable. A sealed
connection-wide generation containing the disconnected account may still need to
fail and restart; unlink does not rewrite its immutable captured account set.

IBKR has an additional capture-to-queue boundary. `SyncQueue` now verifies the
handoff's original AccountProvider UUID/revision and active historical policy
after acquiring the provider Sync and Account locks, before selecting a child
input. A still-valid provider lease cannot reinstall a cleared source pointer.
This check reads only routing; it does not reacquire a request grant in the wrong
lock order or alter retained calculation evidence.

## Retained migration inputs after detachment

Migration archives and installation receipts keep their original link UUIDs.
The runtime-only `RetainedAccountBinding` distinguishes a fully detached source
from a changed or replacement link. It authenticates original source ownership,
requires native migration ownership and the exact mapping, and rejects remaining
direct/legacy links or a conflicting original financial family. It does not
reconstruct a financial owner from an archive or change copier verification.

Wise stops applying the detached account's old overlap policy. Trade Republic
keeps authenticated remote portfolio/cash aliases for connection-wide routing
while dropping the detached account's cached price fallback. Binance still
validates its signed installation but supplies no detached-account history seed.
Current link state remains in request input verification, so captured requests
reject detachment. A replacement AccountProvider still requires reconciliation;
malformed source data does not gain an unlink bypass. No cursor reset, receipt
rewrite or financial ownership reassignment occurs.

## Acceptance still required

Tests cover native and mixed unlink, migrated tracking preservation, current
permissions, rollback, competing sessions, stale publication, retained financial
evidence and IBKR handoff races. Ruby/Bundler are unavailable in this workspace,
so this is authored coverage, not an executed acceptance result.

Account deletion/retirement, connection-wide remote disconnect, full-family erase,
generic relinking, source-specific UI controls and historical replay on relink
remain separate lifecycle gates. Retained migration input collectors also need
provider-specific runtime acceptance for their detached-account behavior. See
[implementation status](provider-implementation-status.md) and
[shared lifecycle admission](provider-shared-lifecycle.md).
