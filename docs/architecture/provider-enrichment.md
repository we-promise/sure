# Provider category and account enrichment

The shared writer now consumes the existing Plaid category and account hints.
These changes are written with Minitest coverage, but the tests have not been run
in this workspace. They do not activate Plaid or any other gated provider.

## Categories

`Ingestion::CategoryMatcher` selects the legacy Plaid algorithm only when the
captured hints say `normalization: "legacy_ascii"`. Other providers retain their
existing translation-first Unicode matcher. The legacy algorithm preserves:

1. The literal detailed-key tier, comparing a normalized user category name with
   the original lowercase taxonomy key. Because the normalization changes
   underscores to spaces, most underscore-containing detailed keys do not match
   this tier. Fixing that behavior is a separate reclassification decision.
2. Detailed aliases before parent aliases, retaining the category collection's
   iteration order within each tier.
3. ASCII category-name normalization, untouched alias spelling, the same plural
   matching and removal of `and` anywhere in a name during final comparison.

Plaid transaction records also capture `category_bootstrap: "empty_family"`.
The financial writer initializes defaults when it processes the first eligible
row in an empty family, before checking the account's auto-category setting. This
retains lazy initialization even when matching is disabled. The native identity
writer now skips merchant/category effects for an already protected Entry or a
retired pending alias; a protected first row therefore no longer initializes
defaults as the legacy eager matcher did. Empty pages, removed-only pages,
pending rows excluded by the adapter, and secondary source observations also do
not bootstrap categories. Existing categories are preserved;
the existing `find_or_create_by!` bootstrap makes ordinary replay idempotent.

This is a preservation bridge, not a completed replay policy. The legacy matcher
uses current family categories and the bootstrap uses the current worker locale.
Category snapshots, locale/version capture and ruleset selection must be pinned
before advertising deterministic historical reprocessing. The captured candidate
hints alone cannot preserve a user's category catalog across time. Category
bootstrap and transaction changes share the batch transaction, so a failed batch
does not commit an independent category setup.

## Account and liability fields

`Ingestion::AccountEnrichment` runs only under the authoritative balance writer's
connection fence and account lock. It validates both hint objects before applying
either. It uses the existing linked accountable; no metadata is constantized, and
an unexpected accountable type is quarantined instead of replacing that object.

`account_enrichment` permits account `name` and accountable `subtype`. Both use
the existing `Enrichable` behavior, respecting field locks and recording
`DataEnrichment` provenance. A replay after a user locks either field preserves
that user's value. Failed enrichment validation raises within the batch
transaction so an unsuccessful save cannot leave a committed enrichment log.

`accountable_attributes` permits only CreditCard `minimum_payment`/`apr` and Loan
`rate_type`/`interest_rate`/`initial_balance`/`term_months`. Decimal fields require
finite `BigDecimal` values, terms require integers, and nil is distinct from
omission. Strategies are explicit:

| Strategy | Behavior | Current use |
| --- | --- | --- |
| `enrich` | Uses field locks and provenance logging. | Available to adapters declaring actual enrichment semantics. |
| `update` | Directly updates declared fields, including nil clears. | Plaid mortgage and student-loan legacy behavior. |
| `update_non_null` | Directly updates only nonnil declared fields. | Plaid credit-card legacy helper behavior. |

The old credit helper's name suggested enrichment, but its implementation called
`update!` after removing nils and bypassed locks. Native Plaid now declares that
exception accurately. Changing liability fields to honor locks requires a
separate, explicit behavior decision; the migration must not imply they were
already lock-aware. Direct-update paths retain their old lack of DataEnrichment
logging, while the actual account name/subtype enrichment remains lock-aware.

Plaid liabilities are optional after a valid account/balance read. A failed
liability HTTP response or invalid liability ownership now produces a partial
Page containing the fresh account balance, an explicit warning, and sanitized
failure evidence. An invalid response body is retained in encrypted evidence.
Previously persisted liability hints are stripped before this read, so failure
cannot replay stale minimum-payment/APR/loan values. The shared runtime may apply
the valid balance while withholding complete coverage and reporting a partial
sync. Invalid core account identity/balance data still fails the balance read.

Remaining acceptance work includes runtime tests, source identity backfill,
historical matching snapshots, enrollment, per-source lifecycle ownership and
cutover/rollback verification. A database validation failure in the typed writer
still aborts its batch; unlike the old credit helper's rescued `false` return,
it cannot silently claim successful liability application.
