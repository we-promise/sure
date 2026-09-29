# Optional transaction timestamps

A transaction's accounting `date` controls grouping, balances, and reports. Its
optional `transacted_at` records when it occurred. Unknown times remain empty;
existing transactions are not backfilled with creation times or midnight.

## CSV imports

Map the date or datetime column and leave the format on **Detect automatically**.
Sure checks all distinct nonblank values against supported formats. It selects a
format only when the interpretation is unambiguous. Otherwise, choose a format
using the previews, correct invalid rows, or convert the CSV to a supported format
and upload it again. Two-digit years always require a manual choice.

The ISO 8601 timestamp option accepts values such as
`2026-09-17T14:48Z`, `2026-09-17T14:48:50Z` and
`2026-09-17T16:48:50.123456+02:00`. An explicit timezone
offset is required. Timestamp precision is retained up to six fractional digits.
Date-only formats must match the complete value; they cannot discard a time suffix.

When the date column contains timestamps, choose how to derive the accounting date:

- **Keep the date written in the file** (default): use its source calendar date.
- **Use my Sure timezone**: convert to the family's timezone, then use that date.

The configuration records the timezone so later background processing uses the
same interpretation as the preview. A separate optional timestamp column is also
supported. When both columns are mapped, the explicit accounting date wins.

Re-imports prefer exact timestamp matches and retain the existing accounting date.
The original CSV instant and source date remain matching metadata after a manual
correction. An explicit date in a later CSV cannot claim a different dated row
solely because the timestamp matches; cross-date matches without source-date
provenance require review rather than guessing.
Same-day CSV exports of manually corrected dates or times can match the existing
entry by its current instant while retaining the original CSV provenance. Sure's
transaction CSV export also includes `sure_entry_id` to identify a corrected
entry when its accounting date and original CSV date differ. This ID is used
only within the selected account when the row's current fields still match.
Older exports without the ID fail for review if a current-time match conflicts
with the stored original CSV date; they cannot safely distinguish a correction
from a different transaction.
Date-only rows never erase a known time. If old entries have no time and more than
one correspondence is possible, the import reports the ambiguous row and rolls
back rather than guessing. No transaction is identified by timestamp alone:
account, amount, currency, and the mapped name still participate in matching.

## Manual editing and display

The optional date/time input lives under **Details** in transaction creation and
editing. It uses the family's timezone and can be cleared. It is independent of
the accounting date. An explicit manual correction or clear is protected from
CSV re-imports. Split children inherit their parent's timestamp.

The native browser input, import preview, and list tooltip display whole seconds;
an unchanged input preserves any finer imported precision. Nonexistent local times
during a daylight-saving clock change are rejected. For an ambiguous repeated
hour, a newly entered local value uses Rails' timezone resolution; an unchanged
existing value keeps its original
instant. Offset-bearing CSV timestamps are unambiguous.

The default transaction list sorts by accounting date, then known occurrence times
(latest first), followed by entries with unknown times in their existing order.
Creation time and ID break ties. The list applies the new order when refreshed or revisited.
Hovering over a timestamped transaction's name shows its local timestamp.

## Export and compatibility

Transaction CSV exports include separate `date` and `transacted_at` columns. Map
both to preserve their independent values. Trade CSVs also carry the timestamp,
including when a transaction has been converted to a trade. NDJSON backups restore
timestamps, source-date and Sure CSV identity provenance, and manual timestamp
protection, including split transactions. Older backups that omit timestamps
remain supported.

Transaction API responses include a nullable, read-only `transacted_at` field in
UTC ISO 8601 format. The existing `date` field keeps its meaning.
