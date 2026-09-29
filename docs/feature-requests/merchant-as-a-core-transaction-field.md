# Feature request: Make merchants a first-class optional part of transactions

## Problem

Transactions can already be associated with a merchant, but the association is easy to miss and unevenly supported across the transaction experience. People should be able to identify the merchant at a glance, set or change it without opening a separate editor, and carry it through data import and export. This matters especially when a bank's transaction description is abbreviated or unfamiliar.

## Proposed experience

Treat merchant as a first-class, optional transaction attribute, alongside categories and tags. The transaction list already shows the merchant name in its secondary text when one is assigned. On wide rows, the leading image currently prefers an activity/security logo, then a merchant logo, and otherwise shows a circular one-letter mark derived from the transaction description. On mobile, the category icon is primary, with a small activity/security or merchant logo overlaid when available. Keep these useful existing fallbacks and make the merchant information and editing affordance more consistent:

- When the displayed merchant logo or fallback mark is hovered or keyboard-focused, make the merchant name easy to identify. This is especially useful when a logo is unfamiliar; keep the existing transaction-description letter mark as the fallback when no logo is available.
- Let users optionally enter a custom logo URL for a family merchant. A manually provided logo should take precedence over the Brandfetch logo generated from its website and remain selected when the website changes; clearing the custom logo should return to the generated logo when available, then the existing fallback.
- Let people select, change, or clear a merchant inline from the transaction list, using a searchable picker and compact row treatment modeled on the tag interaction in [#3734](https://github.com/we-promise/sure/pull/3734). Keep transaction detail editing available as well.
- Support merchants consistently across transaction import/export: CSV import should map an optional merchant column to the appropriate family merchant, and CSV export should include the association for a round trip. Coordinate with the in-progress [#3721](https://github.com/we-promise/sure/pull/3721) CSV import mapping so merchant support lands as part of this end-to-end experience, alongside categories and tags.
- Preserve the native full-data backup/import behavior added in [#3671](https://github.com/we-promise/sure/pull/3671), including provider-assigned merchants referenced by transactions. Treat it as the baseline for merchant round trips and keep the CSV workflow consistent with it.
- Offer merchant selection in the initial manual transaction entry flow, addressing the gap reported in [#836](https://github.com/we-promise/sure/issues/836), so people do not have to reopen a newly created transaction to add one.

Merchants remain optional: existing transactions, imports, exports, and manual entry must continue to work with no merchant selected. Provider merchants should remain read-only where they are shared or provider-managed; family-specific editing must not mutate shared merchant records.

## Why this is useful

Merchant names often explain a transaction more clearly than a bank-provided description. Making the association visible and quick to edit helps people verify automatic matching, correct it when needed, and recognize transactions without adding more category or tag content to every row.

## Acceptance criteria

- [ ] Merchant remains optional throughout the transaction lifecycle.
- [ ] Transaction rows expose a selected merchant clearly, with logo fallback and an accessible way to identify the merchant by name.
- [ ] A family merchant can optionally use a manually entered logo URL, which takes precedence over a Brandfetch-generated logo until cleared.
- [ ] People can select, change, and clear a merchant inline using a row interaction consistent with [#3734](https://github.com/we-promise/sure/pull/3734), with the same association available in transaction details.
- [ ] The initial manual transaction form can optionally set a merchant, covering [#836](https://github.com/we-promise/sure/issues/836).
- [ ] Transaction CSV import can consume an optional merchant field and associate it safely with a family merchant, coordinated with [#3721](https://github.com/we-promise/sure/pull/3721).
- [ ] Transaction CSV export includes optional merchant data in a format that can be imported again.
- [ ] Native full-data import/export preserves transaction merchant associations, building on [#3671](https://github.com/we-promise/sure/pull/3671).
- [ ] Missing merchant values remain valid, and provider-managed shared merchants are not modified as a side effect.
- [ ] The row treatment works on narrow screens and does not obscure category, tags, or transaction amount.
