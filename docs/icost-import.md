# Local iCost import

The iCost workflow is available at `/icost_imports`. Upload a UTF-8 CSV or a
single-sheet XLSX, inspect the preview and resolve warnings before publishing.
It uses no AI, bank connector, geocoding, map tiles or remote image requests.

## Field fidelity and accounting

The archive stores the original document bytes and SHA-256, sheet name, ordered
headers and cell values, unknown columns, source row number, stable source ID and
row hash. Source fields are immutable; review choices are separate. Dates retain
source time precision without inventing a timezone. Numeric XML lexemes remain
strings in the source; normalized amounts use decimal arithmetic. Amounts outside
the native ledger's decimal(19,4) precision remain in review.

The 21 iCost columns are represented explicitly: date, type, amount, first/second
category, account 1/2, note, currency, tags, book, location, refund, discount, fee,
three image links and three image attachment references. Ordinary income and
expenses use native entries, categories and tags. Book names remain structured
and also have a native book tag for filtering. Category hierarchy conflicts are
rejected rather than flattened. No opening balance or account type is guessed;
new ledger entries require an existing visible writable manual account with the
same currency.

A transfer requires explicit source and destination accounts. Native transfer
rules determine the destination account's treatment; a deposit-to-deposit
transfer creates two confirmed legs excluded from income and expenses. Different
currencies require additional facts and are rejected by this workflow. Nonzero
refund, discount and fee values, refund postings and installment creation remain
structured review records until their accounting relationships can be established.
An export without IDs cannot prove refund links or installment schedules.

## Location and attachments

`位置` is shown verbatim. Optional explicit `纬度`, `经度` and `坐标系` columns are
stored separately and range checked. An unknown coordinate system remains
`unknown`; address text is never converted into coordinates. References to images
are escaped text, not automatic fetches or imported attachments. Original file
bytes preserve any embedded content but this importer does not extract media.

## Replay and existing entries

Same-file uploads return the existing batch. Publishing is serialized by family
and record locks; published row hashes in another batch require duplicate review.
Identical rows within one file remain distinct source rows. Missing source IDs
prevent a guarantee of semantic deduplication across independently edited exports.

Legacy local CSV imports are adopted only when the exact file/sheet/row identity,
row hash, date, currency, signed amount, account, categories and tags match. This
adds a provenance association without rewriting native entries or their import
ownership. Published rows whose native entries are later deleted are not silently
recreated. Deleting an archive does not delete ledger entries.

The importer does not call account sync or AutoSync. Mixed-currency existing
entries, trades or holdings require review before local balance materialization,
so this flow cannot silently seek FX or security prices. iCost ordinary types are
also excluded from automatic inferred transfer matching.

## Migration and rollback

`20261024160000_create_icost_imports` adds two tables and nullable references to
native entries. It performs no data backfill. The explicit upload operation stages
and links source records. The migration's down operation removes the source
archive; take and restore-test a database/storage backup before reverting it.
Rolling application code back can retain the additive tables and their data.

Tests use synthetic fixtures. Never commit real exports, source archives, database
backups, `.env.local`, or credentials. `/imports/` is excluded from Docker builds.
