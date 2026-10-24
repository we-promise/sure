# Category emoji

Categories may store an optional `emoji` separately from their existing `lucide_icon`.
The web interface displays the emoji when present, including category selectors,
transaction details and lists, splits, budgets, reports and dashboard legends.
Clearing the emoji restores the saved Lucide icon. Selecting a Lucide icon clears
the override. Parent/child relationships and inherited colors are unchanged;
children do not inherit their parent's emoji.

The model accepts one complete grapheme matching the pinned `unicode-emoji 4.0.4`
Emoji 16 data, including skin tones, ZWJ families/professions, flags and keycaps.
It rejects multiple emoji, arbitrary text, invalid encoding and incomplete
sequences. No code-unit truncation is used. The package was already in the lockfile;
it is now an explicit runtime dependency. Rendering uses escaped text and the
system emoji font, so visual style varies by platform.

The additive migration adds a nullable column without assigning any existing
category. Rolling it down removes emoji overrides; use a verified backup when
those new values need to be retained. Existing category fields are preserved.

The native `.sure` NDJSON archive round trip preserves emoji. Older archives
without the field preserve the current override; an explicit null clears it.
The existing API v1 `icon` contract and generic category CSV format still expose
Lucide, not this new override. No API key or external emoji provider is needed.

The current iCost 21-column format has no category icon field. Imports therefore
do not guess emoji from names or overwrite existing category choices.

New picker labels, help and accessible button labels are translated for all 19
selectable application locales. The iCost interface also supplies all 97 keys
in those locales. Original ledger names, notes, raw column labels and original
timestamps remain source data; they are not translated. Structured decimal
numbers use locale separators without converting through Float; raw values remain
available unchanged in source details.
