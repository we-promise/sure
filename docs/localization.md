# Localization and product-copy contract

This document defines the repository-wide rules for localized product copy in
Sure. It is based only on repository source and independently invented
examples; it contains no deployment or customer provenance.

Language-specific supplements may establish terminology, voice, and review
requirements that apply only to that locale. They must follow the general rules
in this document.

## Language supplements

| Locale | Supplement | Review status |
|---|---|---|
| `de` | [German product copy](localization/de.md) | Approved for implementation; see the supplement for provenance and ongoing review requirements. |

A language supplement may document reviewed, locale-specific decisions about:

- canonical terminology;
- voice, register, and forms of address;
- pluralization and other grammar;
- capitalization, punctuation, and typography;
- formatting or invariant-data boundaries when they differ for that locale; and
- approval status, review provenance, and requirements for future changes.

Do not infer or invent rules for a locale that has not received the relevant
language review. All supplements inherit the repository-wide contract below.

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
