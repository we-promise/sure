# Account source discovery across legacy and native ingestion

Status: provisional inventory implemented, with behavioral tests written but
unrun. No deletion command, migration activation or account mutation is enabled
by this inventory. Ruby/Bundler are unavailable in the current workspace.

[`Account::Destruction::Sources.capture(account:)`](../../app/models/account/destruction/sources.rb)
starts from the financial callback effects graph, then discovers live and retained
owners without reading credentials, financial payloads or encrypted snapshots.
It returns a deeply frozen scalar proof and sorted owner identities. The
`provider_data:account_sources` task accepts explicit `FAMILY_ID` and `ACCOUNT_ID`
and prints the owner summary without modifying data. It has not been run here.

## Discovery paths

| Evidence | Ownership followed |
| --- | --- |
| Current account links and direct Plaid/SimpleFIN FKs | Allowlisted legacy account/item, shared external account/connection, or exact dual migration mapping. |
| Retained financial account identity | Original UUID/family and current live pointer, with a row-version witness. Retired peers still require explicit lifecycle disposition. |
| All source-policy revisions | Retained financial identity and immutable selected legacy/shared source tuple; inactive captured policies survive link removal. Unknown revisions require disposition. |
| Provider-owned holdings | Their financial account and current AccountProvider. |
| SourceRecord, EntrySource and HoldingSource | Current observation batch, historical financial UUIDs, and permanent bootstrap batch/external identity, including inactive mappings. |
| Account-bound batch headers | Original source binding and selected policy, including balance-only captures with no transaction observations. |
| Retained migration receipts | Every original archive checksum version and its mapping/control/connection. |
| Generation account index | Detached fetching, abandoned and completed generation ownership, including captures before account fanout. |
| Account Sync history | All inputs, including superseded ones, selected input pointers, preparation headers and source batches. |
| Documents/imports | Account and Entry import references, base Import::Mapping account targets, statements, source observations and file batches. |

`SourceOwners` resolves provider identity through reviewed manifests and adapter
declarations. Pure native and native-owned dual connections are supported in the
inventory; they do not fall through a legacy-only admission check. A missing
control-backed legacy row requires an explicit retirement disposition unless a
[captured policy](provider-source-policy-retention.md) preserves that exact account's
original parent. Such a row is explicitly marked missing; its parent must still
resolve, and it cannot satisfy a current source claim. Nothing
infers a connection from institution names or an Entry's integration label.

A secondary feed may carry an account binding whose selected policy belongs to a
different integration. Both owners are retained. The policy and binding must
agree on financial account/family/resource; their AccountProvider IDs need not
match. Historical bindings are not replaced with today's live link.

The Sync graph distinguishes deletion edges from ownership witnesses. Root
Account Syncs follow dependent children and successors. Parents/predecessors are
also inspected, but reaching a Family parent does not pull all its sibling jobs
into the deletion set. Polymorphic owners are allowlisted, and combined cycles,
missing owners and foreign-family edges are rejected.

## Unknowns and limits

Before target filtering, discovery rejects unindexed retained archives, unknown
generation projections, orphaned policy references and malformed native batch
routing anywhere in the family. An unresolved detached capture could otherwise
disappear from a target-specific query. These checks use scalar/JSON predicates,
not encrypted financial data. Policy text is compared to UUID text without casting
untrusted policy values to UUIDs.

[Historical command bindings](provider-historical-command-bindings.md) project
both original policy references and the equity snapshot batch into scalar routing.
New captures and normal Plan/Writer retries populate and verify that projection;
an explicit bounded task handles cold older commands. Discovery follows both
owners, including different providers for historical and current balances.
Unindexed commands and deleted secondary policies remain explicitly unresolved;
today's links cannot reconstruct their original ownership. Equity snapshot batches
also have a usable primary historical-policy header and are discoverable before
Account Sync input creation. The new migration and tests remain unrun.

Bounds reject incomplete inventories rather than truncate them: the source graph
permits 100,000 scalar rows, 100 financial accounts, 128 Sync edges of depth and 32
expansion rounds. The financial effects graph and owner resolver have their own
smaller limits. Realistic history sizes and query performance need runtime
acceptance; these are not production capacity guarantees.

The indexed projections' documented integrity limitations remain. Header coverage
is not cryptographic archive verification, and callback-bypassing false initial
projections can defeat reverse discovery. The inventory is provisional; the final
command must admit the complete owner set, verify the relevant originals, lock the
financial graph, recapture and compare before performing any mutation. New or
changed owners require restarting admission, not extending a partially held plan.

## What account deletion still requires

[Retained financial account identities](provider-retained-financial-account.md)
now separate the original UUID from its live Account pointer. Source selection or first publication
captures that identity, and the migration transfers existing SourceRecord FKs.
Account no longer cascades SourceRecords; its preliminary guard refuses retained
observations or policies before dependent callbacks. These changes are written but unrun.

Native deletion still needs the admitted command that retires this identity,
uses retained source-policy ownership, retains Sync ownership, and disposes of live ledger links
without destroying bootstrap evidence. Scheduling, job recovery, statement
relinking races, permissions, owner admission and failure rollback must use the
resulting command together. This inventory performs none of those mutations and
does not claim that a provider's lifecycle is migrated.

See [shared lifecycle](provider-shared-lifecycle.md),
[retained account index](provider-retained-account-index.md),
[generation account index](provider-generation-account-index.md) and
[implementation status](provider-implementation-status.md).
