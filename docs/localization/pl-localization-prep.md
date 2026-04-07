# Polish Localization Preparation

## Current status

- Bond and GUS CPI features are implemented and verified by targeted tests.
- UI tab split for Bond is implemented as: Activity, Positions, Closed.
- Obsolete Bond holdings tab partial was removed.
- Polish locale files for Bond/views are present and actively maintained.

## Verification performed

- Bond and GUS suite:
  - test/models/bond_test.rb
  - test/models/bond_lot_test.rb
  - test/models/gus_inflation_rate_test.rb
  - test/jobs/import_gus_inflation_rates_job_test.rb
  - test/jobs/settle_matured_bond_lots_job_test.rb
  - test/controllers/bonds_controller_test.rb
  - test/controllers/bond_lots_controller_test.rb
  - test/controllers/accounts_controller_test.rb
  - test/controllers/pages_controller_test.rb
  - test/controllers/settings/hostings_controller_test.rb
  - test/controllers/transactions/bulk_deletions_controller_test.rb

## PL scope for next phase

Polish localization baseline is no longer limited to `config/locales/defaults/pl.yml`.
Bond locale files already exist (including `config/locales/views/bonds/pl.yml`) and should be iterated, not created from scratch.

For the next PL phase, prioritize incremental coverage in:

1. Dashboard additions
- config/locales/views/pages/pl.yml (add/adjust bond summary and rate review notice)

2. Self-hosting settings additions
- config/locales/views/settings/hostings/pl.yml (add/adjust GUS CPI settings labels/messages)

3. Accounts additions
- config/locales/views/accounts/pl.yml (review account-type labels and new bond-related strings)

## Recommended execution order

1. Diff PL vs EN locale trees and translate only missing or changed keys.
2. Keep Bond translations aligned with current subtype/product terminology.
3. Run focused smoke checks in Bond views and settings pages.
4. Run targeted controller/model tests for Bond and hostings.
5. Open separate PR for PL localization only.

## PR split recommendation

- PR 1: Bond and GUS CPI feature implementation.
- PR 2: Polish localization.
