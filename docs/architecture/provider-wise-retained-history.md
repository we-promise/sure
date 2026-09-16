# Wise retained account history

`Provider::AccountData::Wise::AccountHistory` supplies the native adapter's
copy-time overlap policy from the existing, checksummed migration archives and
subsequent accepted statement postings. The collector does not publish financial
records, accept source coverage or enable Wise. The adapter remains gated.

The collector reproduces the legacy importer's distinctions:

- A cached row with a present `wise_statement` marker establishes
  `has_statement_history`.
- Other rows, excluding the three supported JAR activity types, establish
  `has_legacy_history`. Their earliest date becomes `legacy_transfer_cutoff`.
- Statements with non-positive movement on or after that date are suppressed;
  incoming statement movements remain eligible. This retains the existing
  deliberate trade-off for historical internal conversions; it does not invent
  an amount/date correlation between transfers and statements.

The relevant legacy date is `created || createdOn || date`, preserving the
timestamp's own offset and calendar date. Only full ISO dates and ISO timestamps
with an explicit offset are accepted. Missing, invalid or ambiguous legacy dates
require an explicit disposition. A null or empty cache proves neither kind of
history. Linked and unlinked source accounts follow the same archive checks.

`RetainedRow` validates the family, provider, original copy run, verified mapping,
source checksum and typed archive. Wise additionally checks the original
financial-account binding, upstream balance ID, currency, parent item and profile.
It accepts subsequent user economic edits because balance and entry values are
not inputs to the policy. A changed binding, currency or profile fails closed.
Archives that lack copy-time account bindings require historical reconciliation;
the collector never reconstructs their original ownership from current links.
A new copy does not resolve an older version's missing binding in the
[retained ownership index](provider-retained-account-index.md).

Work is bounded to 500 accounts, 32 MiB of cumulative typed archive bytes and
50,000 cached transaction rows. Archives are read one at a time. Small live
descriptors pin mapping/checksum/copy-run and current binding context through
the existing `RuntimeInputs` request proof. The full policy snapshot is a frozen
factory input; raw archives are not repeatedly decrypted before HTTP. Genuinely
new unmapped accounts do not acquire a retained policy or invalidate discovery
merely by appearing. Missing proof for a mapped account is an error.

Production construction consumes only the reviewed `wise_account_history`
context. `settings.account_policies` and account metadata cannot authorize
statement fallback. The pure standalone adapter still accepts overlap policy
metadata in protocol tests, but a fallback flag there grants no authority. Each
transaction page retains its policy and source descriptors in encrypted evidence,
not account metadata.

After the shared writer applies a statement page, `Wise::StatementHistory` records
the first accepted main statement posting in the same transaction. Its encrypted
`wise_statement_history` checkpoint references the original applied transaction
batch, payload fingerprint, source binding, profile and stable
`SourceRecord`/`EntrySource`/entry UUIDs. Its cursor and coverage are empty. Empty
responses, suppressed-only outgoing statements, fee-only observations and
secondary-source observations without an authoritative posting do not promote the
policy. A publication rollback rolls back promotion as well. Already applied
pre-protocol batches are not retroactively treated as proof.

Later factory captures validate the bounded original batch, current account/link
and source-policy binding, and historical posting identity. They set
`has_statement_history` while preserving the original transfer cutoff. Later
observations may advance `SourceRecord.ingestion_batch_id`; user economic edits
do not invalidate the original successful posting. Legitimate entry deletion may
detach the live entry reference while retaining its stable posting identity.
Missing batch or posting evidence, account retyping, relinking, profile changes or
source-policy replacement require reconciliation. No financial values are
rewritten to validate history.

A factory selects promotion only when the original batch's `applied_at` is
strictly earlier than its fixed `observed_at` (the Sync's creation time). Its full
validated receipt is frozen into the account-history snapshot and protected by
the existing runtime-input fingerprint. Promotion is intentionally absent from
the live descriptor inventory: the current run, its captured pages and same-Sync
retries retain their original policy. A successor created before promotion also
retains the earlier policy for that run. A later-created Sync skips the legacy
transfer phase once a statement posting has established history. This does not
authorize fallback when statement requests fail.

Receipt reads are limited to 64 KiB of encrypted checkpoint state and 16 MiB of
encrypted original batch payload per account, included in the collector's 32 MiB
cumulative read budget. Original proof must remain retained. The payload
fingerprint uses the existing runtime-input application key; application-key
rotation therefore needs an explicit retained-proof strategy. Administrative
deletion of the entire dedicated checkpoint is not a supported reset: absent a
separate immutable anchor it is indistinguishable from never-promoted history.
No cleanup or reset API for these receipts is delivered here.

This policy is historical evidence, not the entire Wise migration acceptance:

- The [profile statement barrier](provider-wise-statement-barrier.md) now stages
  first-window outcomes across the complete inventory and authorizes only the
  all-denied case. A per-account archive cannot grant it. Later-window failures
  cannot erase observed success to widen authority, and fallback does not prove coverage.
- Retained raw rows may not all have reached the old financial tables. Financial
  identity publication, unapplied-cache disposition, coverage acceptance and
  lifecycle admission remain gates. [Native interbalance linking](provider-wise-interbalance-transfers.md)
  now consumes exact committed event proof; ambiguous routing and older captures
  without that proof require disposition.

Focused tests cover archive-derived suppression, transfer continuation, absence
of fallback authorization, empty/JAR/unlinked histories, malformed dates,
provenance, source context drift, new-source behavior and row bounds. Statement
tests additionally cover atomic rollback, secondary-source exclusion, historical
identity retention, economic edits/deletion, clock ties and proof loss. Production
Registry/Syncer cases exercise interrupted replay with the original false policy,
failed publication, and promotion in a later Sync. These tests have not been
executed in the current environment.
