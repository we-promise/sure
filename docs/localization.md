# Localization and product-copy contract

This document defines the repository-wide rules for localized product copy in
Sure. It is based only on repository source and independently invented
examples; it contains no deployment or customer provenance.

Language-specific supplements may establish terminology, voice, and review
requirements that apply only to that locale. They must follow the general rules
in this document.

## General rules

### Owning layer

1. Identify whether text belongs to a locale leaf, source literal, JavaScript
   fallback, generated presentation string, display mapping, provider data,
   user data, or machine schema.
2. Localize product copy at its owning presentation layer. Do not introduce a
   translated value into storage solely to change how it is displayed.
3. Keep fallback copy localized when it is shown to the user. A locale key is
   not sufficient if a hard-coded fallback still supplies visible product copy.
4. Reuse the paired source-locale key structure and interpolation contract
   unless the change intentionally updates every locale that relies on it.

### Interpolation, pluralization, and invariant data

- Keep interpolation names identical to the source contract. Translate the
  surrounding sentence, never an inserted user, provider, brand, or identifier
  value.
- Use the locale's pluralization rules and pass `count:` to count-dependent
  lookups. Do not use source-language constructions such as `account(s)`.
- Preserve user-entered names, notes, prompts, labels, and categories;
  provider-supplied names, descriptions, errors, account data, and API values;
  brands, identifiers, model names, environment-variable names, URLs, and
  accepted standards; and machine-readable filenames, version markers, CSV or
  NDJSON headers, enum values, field names, and round-trip schemas.
- When an invariant stored value needs localized presentation, add a
  display-layer mapping and leave the stored value unchanged.

Independently invented example:

```yaml
de:
  examples:
    accounts_selected:
      one: "%{count} Konto ausgewählt"
      other: "%{count} Konten ausgewählt"
```

### Product-copy review

- Review localized changes for their owning layer, locale fallback behavior,
  plural and interpolation contracts, accessibility copy, source-language
  compatibility, and invariant data.
- Treat existing locale usage as supporting evidence, not automatic authority.
  When a locale has a dedicated supplement, follow its terminology and review
  rules.
- Keep examples, fixtures, PR descriptions, and documentation privacy-safe:
  use independently invented data and do not include customer or deployment
  details.

## German product-copy supplement

### Approval status

- Initial German product-language review: **Approved for implementation on
  2026-08-28**.
- Reviewer: Codex, explicitly designated by the project owner for this review.
- Review type: a dedicated German-language and product-terminology review
  performed separately from the worker that drafted this document. This is an
  AI review and does not claim to be a human native-speaker attestation.
- Every new canonical German term and every semantic change requires another
  explicit review before merge. Repository maintainers retain final merge
  authority and may request human language review.

Current German locale usage is supporting evidence, not authority. The rules
below are approved for implementation within the audit program; PR review
remains the final repository gate.

### Canonical German terms

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

Repository evidence for these provisional choices includes
`config/locales/views/accounts/de.yml`,
`config/locales/views/transactions/de.yml`,
`config/locales/views/categories/de.yml`,
`config/locales/views/merchants/de.yml`,
`config/locales/views/budgets/de.yml`, `config/locales/views/goals/de.yml`,
`config/locales/views/rules/de.yml`, `config/locales/views/settings/de.yml`,
and `config/locales/views/shared/de.yml`.

### Voice and address

- Address the user informally with lowercase *du*, *dir*, *dich*, and the
  matching *dein-* forms.
- Use concise infinitive action labels on buttons and links: *Speichern*,
  *Abbrechen*, *Konto hinzufügen*.
- Address the user directly with natural *du* phrasing in instructions and
  explanatory sentences; avoid clipped pseudo-imperatives when a full sentence
  is clearer.
- Avoid switching to formal *Sie/Ihr* inside a flow. An existing formal form is
  a conflict to resolve, not precedent.

The informal form dominates the repository's current German locales and was
retained by the designated German-language review.

### Capitalization and punctuation

- Capitalize German nouns and use sentence-style capitalization for headings,
  buttons, descriptions, accessible names, and validation messages.
- Keep established brands and technical abbreviations such as Sure, API, CSV,
  IBKR, and SSO unchanged.
- Use all caps only for an established abbreviation or a deliberately approved
  compact rule marker. Source literals such as `IF` and `FOR` are not
  automatically canonical German copy.
- Use normal German punctuation. A question gets a question mark; a complete
  explanatory sentence gets terminal punctuation. Avoid adding punctuation to
  short field labels.
- Prefer the typographic ellipsis `…` for visible continuation. Do not alter
  machine tokens or schema strings for typography.

### German review rule

Every German-copy PR must state whether it follows this supplement or changes
it. The initial supplement is approved for implementation; every new or
semantically changed term remains merge-blocked until its designated German
product-language review is recorded.
