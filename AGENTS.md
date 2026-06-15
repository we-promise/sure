# Agent Instructions

## Scope
- Rails app code lives in `app/`; shared library code in `lib/`; config in `config/`; tests in `test/`.
- Use `.env.local.example` for local setup. Never commit or print secrets from `.env`, `.env.local`, Railway, or prompt input.
- Keep `AGENTS.md` as the only repo instruction file. Preserve the existing `CLAUDE.md` symlink if present.

## Commands
| Task | Command |
| --- | --- |
| Setup | `cp .env.local.example .env.local && bin/setup` |
| Run app | `bin/dev` |
| Full test suite | `bin/rails test` |
| Single test file | `bin/rails test test/models/user_test.rb` |
| System tests | `DISABLE_PARALLELIZATION=true bin/rails test:system` |
| Ruby lint | `bin/rubocop -f github` |
| ERB lint | `bundle exec erb_lint ./app/**/*.erb` |
| JS/CSS lint | `npm run lint` |
| Format check | `npm run format:check` |
| Security scan | `bin/brakeman --no-pager` |
| OpenAPI docs | `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize` |

## Focused verification
| Area | Command |
| --- | --- |
| Bootstrap + workspace picker | `bin/rails test test/services/platform_bootstrap/multi_company_owners_test.rb test/models/impersonation_session_test.rb test/controllers/impersonation_sessions_controller_test.rb test/controllers/pages_controller_test.rb` |
| India defaults | `bin/rails test test/models/family_test.rb test/controllers/registrations_controller_test.rb test/controllers/api/v1/auth_controller_test.rb` |
| Promoted nav + app-shell pages | `bin/rails test test/integration/layout_accessibility_test.rb test/controllers/tax_workbook_imports_controller_test.rb test/controllers/family_exports_controller_test.rb test/controllers/imports_controller_test.rb` |

## Authoritative docs
| Need | File |
| --- | --- |
| Project overview | `README.md` |
| Docker hosting | `docs/hosting/docker.md` |
| Railway deployment | `docs/superpowers/plans/2026-06-10-sure-railway-deployment.md` |
| Multi-company bootstrap | `docs/superpowers/plans/2026-06-10-multi-company-bootstrap.md` |
| Bootstrap design spec | `docs/superpowers/specs/2026-06-10-multi-company-bootstrap-design.md` |
| Bootstrap family-admin plan | `docs/superpowers/plans/2026-06-15-bootstrap-family-admin-access.md` |
| API checklist | `.cursor/rules/api-endpoint-consistency.mdc` |
| UI conventions | `.cursor/rules/project-design.mdc` |
| View conventions | `.cursor/rules/view_conventions.mdc` |
| Stimulus conventions | `.cursor/rules/stimulus_conventions.mdc` |

## Working rules
- Use Minitest and fixtures for behavioral coverage; keep rswag specs documentation-only.
- API endpoint changes need matching Minitest coverage and regenerated `docs/api/openapi.yaml`.
- UI work should use `DS::*`, `icon`, `t()`, and tokens from `app/assets/tailwind/sure-design-system.css`.
- Do not hand-edit generated token output; regenerate with `npm run tokens:build`.
- Bootstrap passwords for `platform_bootstrap:multi_company_owners` must come from hidden prompts or one-shot env vars only.
- Railway production mutations must start with explicit target confirmation: project `stellar-enjoyment`, environment `production`, and the intended service (`sure-web` or `sure-worker`) from `railway status --json`.
- `Tax`, `Imports`, and `Exports` are primary-nav admin surfaces; do not reintroduce them into Settings nav unless the product direction changes.
- Provider metadata belongs in `Transaction#extra`, namespaced by provider.
- Pending support: SimpleFIN uses upstream `pending` or blank/0 `posted` with `transacted_at`; Plaid uses `extra["plaid"]["pending"]`; Lunchflow uses `extra["lunchflow"]["pending"]`; manual/CSV imports have no pending state.
- SimpleFIN FX metadata uses `extra["simplefin"]["fx_from"]` and `extra["simplefin"]["fx_date"]`; SimpleFIN/Lunchflow pending and raw debug behavior are default-off ENV toggles in their initializers.
