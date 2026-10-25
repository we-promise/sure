# Local iCost import

The iCost workflow is available at `/icost_imports`. Upload UTF-8 CSV or
single-sheet XLSX files, inspect the preview and resolve warnings before publishing.
Parsing and accounting use no AI, bank connector, geocoding, map tiles or remote
image requests. The separate, opt-in map workflow is described below.

## Batch imports

Select up to ten files per upload, each up to 10 MB. Each file is staged
independently; a failed file does not discard successful files, and the page
shows the reason for each failure. The standard transaction import upload also
routes XLSX files to the iCost preview instead of trying to decode them as CSV.

The preview groups ordinary income/expense rows by original account and currency.
Choose an accessible, writable manual account for each group and apply the
mapping once. Other accounting warnings remain under review. Later exports reuse
unambiguous confirmed mappings owned by the same user; inaccessible or
wrong-currency accounts still require review.

Posting runs in `IcostPublishJob` on the existing `high_priority` queue. A running
Sidekiq worker is required. The upload form optionally queues posting immediately
for ready rows. Review rows are never automatically posted. Import and history
pages refresh progress while the batch is queued; reopening a page also shows
current counts. Duplicate job delivery remains safe through the existing
family/record locks and source identities. A short-lived cache entry drives the
progress indicator; ledger rows remain the durable source of truth. A failed
batch can be retried from its preview without duplicating posted entries.

## Category map and place matching

Open `/icost_map` from the import history or preview. Leaflet 1.9.4 and its
BSD-2-Clause licence are vendored locally. Category icons/emoji and colours come
from the family's categories. Nearby markers show a count and open a list of
their individual source records. The accessible ledger list remains usable
without JavaScript or map tiles. Map amounts retain the original currency and
sign; pending source rows are labelled and are not financial totals. The page
shows up to 1,000 records, with a category filter and an explicit limit notice.

The basemap loads only after clicking the OpenStreetMap button. The tile service
receives the browser IP and viewed areas; ledger details are never sent. Visible
OSM attribution and ordinary browser caching are retained, and there is no tile
prefetch or offline download. Operators can change `ICOST_MAP_TILE_URL` without
changing application code. Public OSM tiles are best-effort and subject to the
[tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

Only explicit WGS84 coordinates are mapped automatically. Text-only locations
can be matched by entering a public place name plus city/country, selecting a
search result, then confirming its source place. Alternatively click the map or
enter coordinates. Confirmation applies to the same original place name across
the current user's imports, including already recorded rows, without modifying
source fields or accounting. Later exports reuse that confirmed place unless
they already supply explicit WGS84 coordinates. Unknown coordinate systems are
not silently interpreted or converted.

Place searches use Nominatim only on an explicit search submission; no imported
location, note or amount is automatically transmitted. Do not submit private
addresses or confidential material. Responses are cached for 30 days, including
empty results. A shared Redis cache enforces at least 1.1 seconds between network
requests across users/workers, and failures show an actionable message. This is
interactive place matching, not scheduled bulk geocoding or autocomplete. See
the [Nominatim policy](https://operations.osmfoundation.org/policies/nominatim/).
The cache must be available for uncached searches. Operators can change
`ICOST_GEOCODING_URL` to a compatible self-hosted search endpoint; a future paid
preprocessing provider should preserve the same confirmation/provenance boundary.

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

## Interface languages

All 19 selectable application locales have explicit iCost interface translations,
including review reasons, source/location labels and error messages. The raw
column names and values belong to the imported document and remain untranslated.
Original timestamps retain source precision and are not assigned a guessed time
zone. Review creation timestamps use the configured locale's date format, and
structured decimals use locale separators without floating-point rounding.

The focused localization suite checks key parity, interpolation variables,
count-bearing messages and rendered pages without missing translations. This
coverage does not imply that all historical application strings are translated;
the repository still has wider locale gaps and four skipped global i18n checks.
