# Lunch Flow late pending observations

The native Lunch Flow writer now consumes the adapter's `posted_match_policy`
when an ID-less pending observation arrives after a posted transaction. This
closes the posted-first case previously handled only by the legacy entry
processor. It does not enable native readiness or perform a cutover.

The current selected source must be Lunch Flow. A candidate must have a current
posting `SourceRecord` and `EntrySource` for the exact same external account and
financial account. Initial matching uses the legacy policy: exact amount and
currency, a posted date from the pending date through eight days later, and
exact merchant name when the incoming pending record supplies one. A bare Entry,
another provider or another external account cannot supply this proof. Multiple
candidates, conflicting financial identity, and different pending occurrences
competing for one posting refuse publication.

The writer locks and rechecks the posting, retains the pending `SourceRecord`,
and records an immutable `EntrySource` with role `evidence` and match method
`lunchflow_posted_match`. The incoming normalized record remains in its encrypted
batch. No posted Entry or Transaction fields change, including protected or
reconciled fields. Retry follows the saved Entry UUID and verifies its current
posted source proof, so later user edits do not cause a new pending entry.

This rule is limited to late pending observations. The separate
[native pending settlement rule](provider-pending-settlement.md) now handles
pending-first arrival under a different stable posted ID using current source
proof; neither path enables the legacy generic importer heuristic.
The retained pending observation remains live corroborating evidence. Lunch Flow
currently emits no explicit removals and denies pending-absence authority. A
future removal protocol must explicitly decide when this corroboration can be
retired; generic withdrawal currently preserves a posting with such live evidence.

Behavioral tests exercise the production normalizer and LedgerWriter, including
same-page publication, replay, protected fields, exact matching, ambiguity,
different sources, changed identity and source authority. They are authored but
unrun because Ruby/Bundler are unavailable in this workspace. No migrations or
activation were performed.

See [source authority and shared ingestion](multi-source-ingestion.md) and
[implementation status](provider-implementation-status.md).
