# Mercury retained history at cutover

`Mercury::CutoverHistory` is the Mercury-specific final history check used by the
[shared cutover command](provider-up-cutover.md). It runs inside the final
transaction while the exclusive legacy item permit and the caller's fresh copy
and identity verification locks remain held. It performs no provider request,
financial write, cursor acceptance or coverage publication.

The verifier compares the complete bounded Mercury source-account inventory with
the copied mappings and checks the original typed archives, financial links,
remote IDs, USD currency, source creation time and copied item start. A cached
financial row must resolve to the exact original signed bootstrap posting or a
signed retired pending alias. Current identities also match the signed original
amount, currency, date, name, notes and Mercury metadata. Current user edits after
bootstrap remain untouched. An override already present when bootstrap captured
the row cannot be distinguished from an unapplied cache version and requires
explicit disposition.

Mercury's `failed` status has an explicit nonfinancial disposition: legacy and
native importers both skip it. Its copied ID, ownership, amount and dates must
still validate, and no SourceRecord, same-account financial entry or retired
Mercury alias may claim that identity. Failed rows remain in their original
archive. A failure that collides with prior financial evidence refuses cutover.
An unlinked source may contain only an empty cache or these validated failures;
other unlinked caches require reconciliation. Missing, partial, duplicate or
ambiguous rows are never converted into implied coverage.

The result contains a separate first-read Date for each external account:

- A copied explicit item start takes precedence. This deliberately honors that
  user setting in native sync; the legacy Mercury importer ignored it.
- Without an explicit start, an empty account cache uses the later of source
  account creation minus seven days and the current day minus ninety days.
- A nonempty cache uses the latest completed legacy item Sync minus seven days,
  or ninety days when no completed Sync exists.
- Without an explicit start, that account's verified cached creation/posting
  timestamps can widen its own first read. Timestamp boundaries use UTC dates.
  Other accounts retain independent windows.

Cutover stores the result as `mercury_initial_history_start` in each external
account's metadata. The adapter accepts only a strict ISO date. The shared runtime
preserves the hint through discovery, pins it in request-window evidence, and
keeps explicit account/connection dates and completed checkpoint precedence.
These dates request fresh history; they do not assert that retained caches are
complete.

Limits are one hundred accounts, ten thousand cache rows and aggregate stored
cache, retained-account archive and financial-proof budgets of 32 MiB each.
Stored-byte preflight is repeated on materializing queries. This reuses the
existing encrypted archive/proof readers and their historical compressed-decode
limitations; it does not add a streaming decoder.

The authored tests use actual legacy Mercury entry processing, quiesced copying,
signed bootstrap evidence and the production native Syncer. They cover both
history selection and refusal on request-time metadata drift. Ruby/Bundler are
unavailable, so the tests remain unrun. Mercury's production readiness gate is
unchanged; no migration, environment setup or activation was executed.
