# Interface translation coverage

This is the current local multilingual-completion snapshot. It records explicit resource coverage and the interface paths checked in this task; it does not claim an exhaustive review of every hardcoded string or rendered sentence in the repository.

## Completed resource coverage

The latest audit covers **19 selectable locales × 9,000 semantic messages = 171,000 locale/message pairs**. English fallback does not count as an explicit translation. Semantic missing messages: **0**. Interpolation mismatches: **0**. Parse errors: **0**.

The **60 remaining raw alignment differences** are legitimate plural-structure or cross-file placement differences. They are not 60 untranslated messages. Coverage is evaluated after merging each locale's explicit resources and normalizing valid plural forms, without forcing every language to reproduce English leaf structure.

All **47,367 original raw missing leaves across the other 17 languages** have been completed: fr, de, es, it, tr, nb, ca, ro, ru, pl, pt-PT, pt-BR, zh-TW, nl, hu, vi, and uk. These counts describe the resolved historical baseline; they are not a remaining translation plan.

The earlier iCost/emoji phase supplied 107 English leaf keys across all 19 locales (2,033 pairs), and Simplified Chinese completion added 2,949 missing leaves, corrected 48 existing English labels, and upgraded one plural message. Those are completed stage-specific counts, not the current application-wide message total. Chinese day-of-month labels use local formatting (`1日`) without changing recurrence scheduling.

Brands, protocol names, API identifiers, machine values, format-only strings, and intentionally blank labels can correctly remain identical to English. User-entered category names, account names, notes, source columns, and financial content are preserved rather than translated. Private imports were not sent to a translation service. Translating optional provider interfaces does not authorize connecting those providers.

## Interface paths checked and repaired

The task's manual source audit confirmed **31 currently reachable hardcoded-interface issue groups**, plus one template whose current render path was not found. The confirmed groups and related provider, authentication, footer, and rule wording have been repaired. This is a scoped list of verified findings, not an exhaustive count of every hardcoded string in the codebase.

Coverage includes iCost review and original fields, local location display, category emoji and validation, shared forms and confirmation dialogs, dynamic upload and split-row messages, rules, account/provider setup, authentication, and report/dashboard accessibility text. Report dates and CSV human-readable headings are localized while retaining monetary formatting, arithmetic, filters, row/column order, and user category names. Missing-category rows have a stable internal grouping marker, preventing translated or English `Uncategorized` labels from merging them with real user-named categories.

The unused budget-report template received only a local date-format change; it was not enabled or claimed as browser-verified. Dormant XLSX/PDF report exports were not enabled. The workspace audit and report evidence retain these boundaries:

- `icost-code/i18n-audit/hardcoded-ui-audit.md`
- `icost-code/report-localization/evidence.json`
- `icost-code/multilingual-completion/` for per-locale and global audit records

## Verification status

- Latest semantic resource audit: **171,000 explicit locale/message pairs; 0 missing, 0 interpolation mismatches, 0 parse errors**.
- Full frontend suite: **174 tests passed, 0 skipped**.
- Report-specific regression: **5 new tests plus 40 existing controller tests passed**. The combined batch's assertion total is not attributed to Reports alone.
- Full Rails regression: **10,797 runs, 75,572 assertions, 0 failures, 0 errors, 33 existing skips** in the isolated managed-mode test environment. The local application remains self-hosted. The final shared HTML language-attribute fix followed that full-suite snapshot and passed **104 focused tests / 1,678 assertions, 0 failures, errors or skips**, including actual pages in all 19 locales. This is not presented as a second full-suite run after that small fix.
- Changed-source lint: **51 Ruby and 44 ERB files passed**. Independent review found no new financial-calculation, upload-limit, rule-execution or OAuth-permission changes.
- Exact local release revision, image, deployment health, data-preservation fingerprints and Edge observations are recorded separately in the delivery report and workspace `icost-code/validation/` evidence; resource coverage alone does not establish a successful deployment.

Prior Chinese-version commits, full-suite totals, and browser results remain historical evidence. They do not prove deployment or final validation of this multilingual snapshot. The four legacy skipped global `I18nTest` checks remain skipped and are not counted as verified; independent explicit-resource contracts cover the current supported locales.

Relevant regression entry points include:

```sh
bin/rails test test/supported_locale_i18n_test.rb test/zh_cn_i18n_test.rb test/i18n_test.rb
bin/rails test test/integration/icost_localization_test.rb test/integration/category_form_localization_test.rb test/integration/interface_gap_localization_test.rb test/integration/reports_localization_test.rb
```

Resource coverage, plural/interpolation checks, focused rendered-page tests, frontend tests, and final deployment checks establish different things. Keep their results separate; do not infer that every historical page or language has received a complete visual or linguistic review from a zero-missing resource count.
