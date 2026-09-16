# Brex retained history verification

As of this working tree, the Brex history verifier and native per-account date
input are implemented. Tests are authored but unrun because Ruby is unavailable.
No migration, provider activation, live request, or cutover has been performed.
Brex remains gated by `native_ready?`; the implementation and authored tests are
not runtime acceptance of a transfer of ownership.

## Final verification contract

[`Brex::CutoverHistory`](../../app/models/provider/account_data/brex/cutover_history.rb)
accepts persisted `item:`, `connection:`, and `family:` and returns a frozen
`Result(account_starts:)`, keyed by original ExternalAccount UUID with Date
values. It requires the actual exclusive legacy item permit and the final
cutover transaction, the original disabled connection and quiescing control at
epoch zero, and a verified quiesced copy. Its caller must first finish fresh copy
and identity sweeps and hold the ownership, link, policy, and financial inventory
locks throughout. The helper reads and validates; it does not import, select a
source, install dates, or activate a connection.

The retained item must explicitly contain `accounts`, `cash_accounts`, and
`card_accounts` arrays. Account IDs must be unique, and the copied source rows
must exactly match that inventory. Every source snapshot must still equal its
original item account snapshot and copied archive, with matching normalized
currency, balance, available balance, limit, name, status, and account kind.
This catches omitted account imports and unapplied account snapshots. It does
not prove that the legacy remote pagination received every upstream account.

Brex's card transaction feed belongs to the single `card_primary` source.
Physical cards remain evidence within that source, never independent financial
accounts. The verifier replays the retained physical card array through the
native adapter's actual aggregation using an in-memory client. It checks the
canonical identity, count, original physical rows, and normalized aggregate.
Missing balances, mixed currencies, inconsistent totals, and physical-card
identity substitutions refuse. Native minor-unit validation remains strict;
historical inventory shapes that cannot satisfy it require explicit review.
Retained money must have an explicit amount and a recognized currency; scalar
money and invalid-currency fallback are not accepted as cutover evidence.

Each cached transaction must normalize to its exact `brex_<id>` identity and
have one active, nonwithdrawn posting with permanent signed bootstrap evidence.
The evidence must identify the same family, copy run, archive checksum, original
mapping, external account, AccountProvider revision, financial Account and
Transaction UUIDs. Current delegated ownership and pending identity state must
still match. The normalized cached amount, currency, date, name, notes, and Brex
metadata are compared to the **signed original financial snapshot**, so a newer
unapplied cache version does not pass merely because its ID already exists.
Current user amounts, labels, notes, and protections are not overwritten. Derived
accounting classifications are not used as proof of source processing; the
original Brex type and references remain in the compared source metadata.

Rows without proof, duplicate IDs, malformed rows, foreign cash-account IDs,
withdrawn or detached postings, and unknown pending aliases refuse. Brex has no
failed/pending-row suppression contract here: there is no inferred disposition
or absence-based withdrawal. Nonempty unlinked caches refuse. A nil cache is
allowed only for an unlinked discovery source; a linked source needs an explicit
transaction array. An empty array does not claim historical upstream coverage.
Overrides that predate bootstrap and differ from the cache conservatively need
review because there is no earlier signed baseline to distinguish them from a
failed legacy update.

Verification is bounded to 100 financial/discovery sources, 100 physical card
rows, 10,000 retained transactions, 32 MiB cumulative retained archives and
financial proofs (separate budgets), and 1 MiB per current identity state. Stored
cache ciphertext is checked before materialization. These are refusal bounds,
not pagination or an optimized large-account workflow; encrypted historical
decoding can allocate before its decoded-size check.

## First native read

Configured item history start remains a floor. Otherwise each nonempty cached
source uses its most recently created completed legacy Sync's completion time
minus seven days, or the current UTC date minus 90 days when no completion time
exists. Its own earlier initiation/posting dates widen that source's bound. An
empty or unfetched discovery source uses the later of account creation minus
seven days and the 90-day fallback. One account never widens its siblings.
A last-success timestamp alone never excuses an unapplied cache row.

The final cutover coordinator can atomically store each returned ISO date as
`ExternalAccount.metadata['brex_initial_history_start']` while leaving the first
Sync's global start unset. The [native Brex adapter](../../app/models/provider/account_data/brex.rb)
declares and consumes that key through `initial_history_metadata_keys` and
`initial_history_start`. Existing shared window precedence keeps explicit account
or connection configuration and completed checkpoints ahead of the hint.
RequestInputs pins the declared metadata and actual window; inventory deep-merge
preserves the installed hint. A changed hint during HTTP refuses publication
while retaining the captured response.

Brex requests use `posted_at_start`; they do not send an invented upper-bound
filter. These first-read dates are request bounds, never `covered_through`,
upstream completeness acceptance, or instructions to replay the legacy cache.

## Evidence and remaining work

The [history tests](../../test/models/provider/account_data/brex/cutover_history_test.rb)
use actual legacy Entry processing, quiesced copying, signed identity bootstrap,
and native LedgerWriter replay for cash and card transactions. They cover
original UUID/proof retention, protected values, aggregation, inventory and cache
refusals, source drift, ownership admission, and bounded reads. The
[window tests](../../test/models/provider/account_data/brex/history_windows_test.rb)
exercise the production Registry/Syncer path with fake provider responses,
independent dates, checkpoint/configuration precedence, and publication refusal
after metadata drift. Readiness is stubbed only in tests.

The direct legacy path now uses
[`BrexItem::LegacyAccess`](../../app/models/brex_item/legacy_access.rb) at the
Importer, Syncer, account/transaction/entry processors, snapshot writers, and
child scheduling entry points. It retains the real item permit across HTTP but
rejects HTTP inside a database transaction. A provider client is built from
freshly admitted credentials; injected clients retain their original configuration
and actual Brex clients must match it. Credentials and source/cache context are
rechecked before response publication, including responses with no new rows.
Missing account or transaction collections remain failed responses.

Financial publication uses a short savepoint with Account, item, source, external
account and link locks, all NOWAIT. It rechecks family, financial type/currency/
status, exact source and shared-copy mapping, and cached inputs. It reloads the
financial import adapter for each entry; a transaction loop pins its original
cache and refuses later rows if that cache or binding changes. Admission errors
propagate through existing partial-failure handlers. Raised callbacks after SQL
roll back local publication before the outer transaction processor reports an
ordinary row failure. Earlier successfully committed rows remain committed.

The [direct writer tests](../../test/models/brex_item/legacy_access_test.rb) use
real commits and database sessions for drain/row contention, ownership and cache
drift, no-transaction HTTP, Sync cancellation, and SQL rollback. Older fixture
tests substitute only physical fence acquisition; fake-Sync formatting tests
call the admitted orchestration seam. They do not demonstrate real admission.
The separate [lifecycle slice](brex-lifecycle-admission.md) covers its own browser,
credential and source-selection boundaries.

Runtime acceptance, provider completeness and date behavior, large-history cost,
and native setup remain unverified. Per-entry cache fingerprints conservatively
reread retained input and need performance acceptance for large histories.
This helper neither repairs missing history nor authorizes reconciliation of
ambiguous financial records. Legacy multi-provider financial authority and broad
family post-sync matching remain separate shared-runtime concerns.
