# Feature request: Make merchants a first-class optional part of transactions

## Problem

Transactions can already be associated with a merchant, but the association is easy to miss and unevenly supported across the transaction experience. People should be able to identify the merchant at a glance, set or change it without opening a separate editor, and carry it through data import and export. This matters especially when a bank's transaction description is abbreviated or unfamiliar.

## Proposed experience

Treat merchant as a first-class, optional transaction attribute, alongside categories and tags. The transaction list already shows the merchant name in its secondary text when one is assigned. On wide rows, the leading image currently prefers an activity/security logo, then a merchant logo, and otherwise shows a circular one-letter mark derived from the transaction description. On mobile, the category icon is primary, with a small activity/security or merchant logo overlaid when available. Keep these useful existing fallbacks and make the merchant information and editing affordance more consistent:

- When the displayed merchant logo or fallback mark is hovered or keyboard-focused, make the merchant name easy to identify. This is especially useful when a logo is unfamiliar; keep the existing transaction-description letter mark as the fallback when no logo is available.
- Let users optionally enter a custom logo URL for a family merchant. A manually provided logo should take precedence over the Brandfetch logo generated from its website and remain selected when the website changes; clearing the custom logo should return to the generated logo when available, then the existing fallback.
- Let people select, change, or clear a merchant inline from the transaction list, using a searchable picker similar to the recent inline tag experience. Keep transaction detail editing available as well.
- Include merchant as an optional field in transaction import and export workflows. Imports should map supplied merchant data to the appropriate family merchant when possible, and exports should preserve the association for round trips. Omitting merchant data must remain valid and must not erase an existing merchant unintentionally.
- Offer merchant selection in the initial manual transaction entry flow so people do not have to reopen a newly created transaction to add one.

Merchants remain optional: existing transactions, imports, exports, and manual entry must continue to work with no merchant selected. Provider merchants should remain read-only where they are shared or provider-managed; family-specific editing must not mutate shared merchant records.

## Why this is useful

Merchant names often explain a transaction more clearly than a bank-provided description. Making the association visible and quick to edit helps people verify automatic matching, correct it when needed, and recognize transactions without adding more category or tag content to every row.

## Related work

- [#836: Add merchant to the initial manual transaction input](https://github.com/we-promise/sure/issues/836) covers the manual-entry gap.
- [#3734: Show tags in the transaction list with an inline picker](https://github.com/we-promise/sure/pull/3734) is a useful interaction precedent for inline editing and compact row summaries.
- [#3721: Add merchant column mapping to CSV imports](https://github.com/we-promise/sure/pull/3721) is in progress and should be coordinated with import support here.
- [#3671: Export and import provider-assigned merchants](https://github.com/we-promise/sure/pull/3671) added merchant support to Sure's full-data export/import round trip. This request also calls for checking transaction CSV workflows.

## Acceptance criteria

- [ ] Merchant remains optional throughout the transaction lifecycle.
- [ ] Transaction rows expose a selected merchant clearly, with logo fallback and an accessible way to identify the merchant by name.
- [ ] A family merchant can optionally use a manually entered logo URL, which takes precedence over a Brandfetch-generated logo until cleared.
- [ ] People can select, change, and clear a merchant inline, with the same association available in transaction details.
- [ ] The initial manual transaction form can optionally set a merchant.
- [ ] Transaction import can consume an optional merchant field and associate it safely with a family merchant.
- [ ] Transaction export includes optional merchant data in a format that can be imported again.
- [ ] Missing merchant values remain valid, and provider-managed shared merchants are not modified as a side effect.
- [ ] The row treatment works on narrow screens and does not obscure category, tags, or transaction amount.
