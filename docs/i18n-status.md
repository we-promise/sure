# Interface translation coverage

Audit date: 2026-10-24. This is a scoped coverage snapshot, not a claim that every rendered sentence in every language has been reviewed.

The iCost review, original fields, local location display, category emoji, category create/update/error messages, and shared submitting state have 107 explicit English message keys across all 19 selectable locales (2,033 locale/key pairs). Named interpolation parameters match. No user-entered category names, notes, or other financial content are translated.

Simplified Chinese now explicitly covers all English application resource keys, including custom application namespaces in `defaults/*.yml`. Generic Rails date/number/error defaults are checked separately. The completion adds 2,949 previously missing leaves, translates 48 existing English interface labels, and upgrades one PDF-import message from a string to a plural mapping while preserving the Chinese wording. Intentionally blank provider subtype labels match the English source and remain blank. Brands, protocol names, identifiers, and format-only strings may correctly equal English.

Chinese day-of-month labels also use local formatting (`1日`) in preferences and recurring cadence descriptions; English and Catalan behavior is preserved. This formatting fix does not change recurrence scheduling.

Regression checks:

```sh
bin/rails test test/zh_cn_i18n_test.rb test/i18n_test.rb test/integration/icost_localization_test.rb test/integration/category_form_localization_test.rb
```

`ZhCnI18nTest` compares explicit source resources without counting English fallback, verifies named interpolation, renders plural messages at counts 0/1/2, and checks Chinese date/time and decimal formatting. The existing four skipped global `I18nTest` checks remain skipped; the new coverage contract does not depend on them.

## Remaining historical application gaps

All counts below are missing explicit English leaf-key equivalents. Plural-normalized counts can differ. Fallback text does not count as a translation.

| Locale | Missing leaf-key equivalents |
| --- | ---: |
| fr | 599 |
| de | 1312 |
| es | 2289 |
| it | 2468 |
| tr | 243 |
| nb | 7924 |
| ca | 243 |
| ro | 7627 |
| ru | 253 |
| pl | 566 |
| pt-PT | 2025 |
| pt-BR | 6577 |
| zh-TW | 1968 |
| nl | 5979 |
| hu | 3658 |
| vi | 3382 |
| uk | 254 |

Total: 47,367 locale/key pairs across 17 languages. These historical gaps are not completed by the new-feature translations.

Completion sequence:

1. Finish the smallest missing sets (tr, ca, ru, uk), retaining each locale's plural grammar; validate interpolation and rendered forms.
2. Complete fr/pl/de/zh-TW/pt-PT/es/it by product area, starting with navigation, forms, imports, and financial reports.
3. Complete vi/hu/nl/pt-BR/ro/nb in domain batches, with fluent-language review for financial terminology and accessible labels.
4. Scan remaining hardcoded interface text and dynamic key usage; add rendering coverage where static resource comparisons cannot prove completeness. Run full regression checks and browser checks for each completed locale before claiming completion.

Do not populate untranslated strings with copies of English just to satisfy key counts. Do not translate user data or send private import files to a translation service. Optional external providers remain disconnected; translating their interface does not authorize enabling them.
