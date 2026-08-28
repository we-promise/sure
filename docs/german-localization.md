# German product copy contract

This document defines the shared German product language for Sure. It is based only on repository source and independently invented examples. It contains no deployment or customer provenance.

## Approval status

- Initial German product-language review: **Approved for implementation on 2026-08-28**.
- Reviewer: Codex, explicitly designated by the project owner for this review.
- Review type: a dedicated German-language and product-terminology review performed separately from the worker that drafted this file. This is an AI review and does not claim to be a human native-speaker attestation.
- Every new canonical term and every semantic change requires another explicit review before merge. Repository maintainers retain final merge authority and may request human language review.

Current German locale usage is supporting evidence, not authority. The rules below are approved for implementation within the audit program; PR review remains the final repository gate.

## Canonical terms

| English concept | Provisional German | Usage rule |
|---|---|---|
| account | Konto; plural Konten | Use for the product object. Preserve a user-entered account name unchanged. |
| transaction | Transaktion; plural Transaktionen | Use for the generic product object. Use *Buchung* only when the copy deliberately refers to a bank booking rather than Sure's generic transaction object. |
| category | Kategorie; plural Kategorien | Use for product categories. Preserve user-created category names unchanged. |
| merchant | Händler; plural Händler | Use for the product field or object. Preserve provider-supplied merchant text unchanged. |
| budget | Budget; plural Budgets | Keep the established loanword. |
| goal | Ziel; plural Ziele | Use for the planning object. |
| rule | Regel; plural Regeln | Use for the automation object. |
| provider | Anbieter; plural Anbieter | Use for a generic integration provider. Keep provider and service brand names unchanged. |
| settings | Einstellungen | Use for the product area. |
| family / group | Familie / Gruppe | Follow the configured product moniker. Do not replace a configured *Gruppe* with *Familie* or invent *Haushalt* as a universal synonym. |
| pending | ausstehend / vorgemerkt | Use *ausstehend* for an unfinished process or approval. Use *vorgemerkt* for a bank transaction reported as pending by its provider. Use *geplant* for a deliberately scheduled future action. |

Repository evidence for these provisional choices includes `config/locales/views/accounts/de.yml`, `config/locales/views/transactions/de.yml`, `config/locales/views/categories/de.yml`, `config/locales/views/merchants/de.yml`, `config/locales/views/budgets/de.yml`, `config/locales/views/goals/de.yml`, `config/locales/views/rules/de.yml`, `config/locales/views/settings/de.yml`, and `config/locales/views/shared/de.yml`.

## Voice and address

- Address the user informally with lowercase *du*, *dir*, *dich*, and the matching *dein-* forms.
- Use concise infinitive action labels on buttons and links: *Speichern*, *Abbrechen*, *Konto hinzufügen*.
- Address the user directly with natural *du* phrasing in instructions and explanatory sentences; avoid clipped pseudo-imperatives when a full sentence is clearer.
- Avoid switching to formal *Sie/Ihr* inside a flow. An existing formal form is a conflict to resolve, not precedent.
- Do not address provider data, user-entered text, logs, or machine output as though it were product copy.

The informal form dominates the repository's current German locales and was retained by the designated German-language review.

## Capitalization and punctuation

- Capitalize German nouns and use sentence-style capitalization for headings, buttons, descriptions, accessible names, and validation messages.
- Keep established brands and technical abbreviations such as Sure, API, CSV, IBKR, and SSO unchanged.
- Use all caps only for an established abbreviation or a deliberately approved compact rule marker. Source literals such as `IF` and `FOR` are not automatically canonical German copy.
- Use normal German punctuation. A question gets a question mark; a complete explanatory sentence gets terminal punctuation. Avoid adding punctuation to short field labels.
- Prefer the typographic ellipsis `…` for visible continuation. Do not alter machine tokens or schema strings for typography.

## Plurals and interpolation

- Use I18n `one` and `other` branches for count-dependent copy. Do not use English constructions such as `account(s)`.
- Pass `count:` to pluralized lookups and keep all interpolation names identical to the English source contract.
- Translate the sentence around an interpolation, never the user or provider value inserted into it.
- German zero counts normally use the `other` branch unless the product deliberately supplies a separate empty-state sentence.

Independently invented example:

```yaml
de:
  examples:
    accounts_selected:
      one: "%{count} Konto ausgewählt"
      other: "%{count} Konten ausgewählt"
```

## Non-localizable and invariant data

Preserve these values byte-for-byte unless a separately reviewed, versioned interface change says otherwise:

- user-entered names, notes, prompts, labels, and categories;
- provider-supplied names, descriptions, errors, account data, and API field values;
- brands, identifiers, model names, environment-variable names, URLs, and accepted financial or technical standards;
- machine-readable filenames, version markers, CSV or NDJSON headers, enum values, field names, and round-trip schemas.

When an invariant stored value needs a localized presentation, add a display-layer mapping and leave the stored value unchanged.

## Conflict resolution

1. Identify the owning layer: locale leaf, source literal, JavaScript fallback, generated presentation string, display mapping, provider data, user data, or machine schema.
2. Check this contract and the paired English/German locale source. Frequency is evidence only.
3. Preserve user, provider, brand, identifier, standard, and machine-schema data.
4. If two German terms compete, the meaning or tone changes, or a source marker may be intentional, mark the term unresolved. Do not choose by majority count alone.
5. Propose the smallest privacy-safe contract update with an independently invented example.
6. Obtain explicit approval from the designated German product-language reviewer before merge. Record whether the review was performed by a person or an AI; never imply a human or native-speaker attestation that did not occur. Without approval, the affected term remains unresolved.

## Review rule

Every German-copy PR must state whether it follows this contract or changes it. Reviewers verify the owning layer, informal address, capitalization, plural and interpolation contracts, accessibility copy, English compatibility, and invariant data. The initial contract is approved for implementation; every new or semantically changed term remains merge-blocked until its designated German product-language review is recorded.
