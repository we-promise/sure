# Plaid cached changes and checkpoint handoff

Status: an internal read-only plan and focused behavioral tests are written and
have not run. The [durable journal](plaid-cached-change-journal.md) now consumes
this plan in migration preparation. Neither path installs a cursor or establishes
an accepted cutover. Both Plaid regions use this plan.

The separate [deployment binding](provider-plaid-deployment-binding.md) now pins
the copied item's region, environment and application credentials to the original
quiesced copy. That binding establishes configuration provenance only; it does
not accept the cached changes or copied cursor described here.

## A completed legacy sync does not prove cursor acceptance

The legacy item importer stores account transaction caches and then advances
`PlaidItem#next_cursor`. Account transaction processing runs afterward. The
account processor catches failures, so completion of the enclosing Sync does not
prove that every cached addition, modification or removal reached the ledger.
Copying the cursor directly would risk skipping those changes permanently.

The retained account cache also has limits. Each import replaces its
`modified`, `added` and `removed` arrays. There is no per-account cache generation
or starting cursor. Accounts absent from the latest account inventory can retain
older caches. Item-wide removals lacking an account ID were not retained by the
legacy account filter. Consequently, even perfect replay of these archives does
not prove that they contain the complete delta ending at the copied item cursor.

## Bounded observation planning

`Provider::AccountData::Plaid::CheckpointBootstrapPlan` reads the original verified
quiesced copy through the retained-copy verifier. It requires the migration control
and its authorized family, keeps the declared legacy writer fence for the read,
and reads one source account and at most 500 physical observations per call. Archive
byte/chunk limits still apply. It never fetches upstream data, changes financial
rows or installs a native checkpoint.

```ruby
plan = Provider::AccountData::Plaid::CheckpointBootstrapPlan.new(
  control: control, family: authorized_family
)
page = plan.page(limit: 100)
next_page = plan.page(cursor: page.next_cursor, limit: 100) if page.next_cursor
```

The immutable document retains each raw row, section, original array index and
account-local ordinal, preserving duplicate occurrences and the legacy processing
order: modifications, additions, removals. Valid additions/modifications include
the existing adapter's canonical record. Pending rows excluded by the selected
legacy preference remain explicit observations. Removals remain source assertions;
reading one does not authorize an Entry deletion. Missing or malformed cache
sections and invalid row identities/normalization appear as blockers. The default
empty object is not treated as a proven empty fetch.

Continuation binds the original copy run, item checksum, source account/link
context, copied cursor, region, pending preference, family timezone and page size.
Normalization uses the family zone or the explicit Rails deployment default
(UTC when unset); invalid zones are rejected. That effective zone is also pinned,
so a different worker's local timezone cannot change timestamp-based dates.
Changing that context requires restarting the read. The continuation is a position
in retained data, not an acceptance receipt. It is an internal value containing
sensitive cursor and ownership context; do not place it in URLs or ordinary logs.
The page document also contains private transaction data and needs protected
storage if a caller persists it.

`page.replayable?` means only that this page has no malformed observations or
incomplete-cache blockers. It does not verify existing financial identities,
authorize posting, accumulate earlier pages' blockers or accept the item cursor.
Every document explicitly sets `cursor_accepted: false` and identifies the missing
legacy coverage evidence, including an empty-account plan.

## Work required before installing a native cursor

The preparation coordinator must retain dispositions for every observation and
reconcile or replay unresolved legacy changes through the protected publication
path. Existing Entry identity proof alone cannot stand in for that work. In
particular, partially processed caches, filtered pending rows and deletions need
explicit outcomes without overwriting user protections or another source's
evidence.

The missing item-wide delta/generation evidence also requires a separate recovery
decision and upstream reconciliation. It cannot be reconstructed from cache
timestamps or a successful legacy Sync. Only after those gaps are resolved, the
current copy/identities are reverified under the complete cutover boundary, and
all staged children have committed may a cursor be accepted atomically with native
ownership. The existing native connection-generation barrier supplies the ongoing
cursor discipline; it is not yet a migration seed API.

See [financial identity bootstrap](plaid-identity-bootstrap.md),
[connection change sets](connection-change-sets.md) and
[migration preparation](provider-migration-preparation.md).

The focused suite is
`test/models/provider/account_data/plaid/checkpoint_bootstrap_plan_test.rb`.
It checks physical ordering, pending exclusions, linked/unlinked accounts,
incomplete caches, source/context drift, protected removal observations, bounded
continuation and absence of publication writes. Runtime verification remains
blocked by the unavailable Ruby environment.
