# Polish Localization Preparation

## Current status

- Bond and GUS CPI features are implemented and verified by targeted tests.
- UI tab split for Bond is implemented as: Activity, Positions, Closed.
- Obsolete Bond holdings tab partial was removed.

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

The repository currently has only one Polish locale file:
- config/locales/defaults/pl.yml

For the next full PL phase, prioritize these files first:

1. Bond domain
- config/locales/views/bonds/pl.yml (missing)

2. Dashboard additions
- config/locales/views/pages/pl.yml (update, add bond summary and rate review notice)

3. Self-hosting settings additions
- config/locales/views/settings/hostings/pl.yml (update, add GUS CPI settings labels/messages)

4. Accounts additions
- config/locales/views/accounts/pl.yml (update, add Bond type labels if needed)

## Recommended execution order

1. Create config/locales/views/bonds/pl.yml from the structure in config/locales/views/bonds/en.yml.
2. Translate only newly introduced keys in pages/settings/accounts files.
3. Run focused smoke checks in Bond views and settings pages.
4. Run targeted controller/model tests for Bond and hostings.
5. Open separate PR for PL localization only.

## PR split recommendation

- PR 1: Bond and GUS CPI feature implementation.
- PR 2: Polish localization.
