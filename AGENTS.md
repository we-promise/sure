# Agent Instructions

## Scope
- Rails app code lives in `app/`; shared library code in `lib/`; config in `config/`; tests in `test/`.
- Use `.env.local.example` for local setup. Never commit or print secrets from `.env`, `.env.local`, Railway, or prompt input.

## Commands
| Task | Command |
| --- | --- |
| Setup | `cp .env.local.example .env.local && bin/setup` |
| Run app | `bin/dev` |
| Test file | `bin/rails test TEST=test/models/user_test.rb` |
| Full tests | `bin/rails test` |
| System tests | `DISABLE_PARALLELIZATION=true bin/rails test:system` |
| Ruby lint | `bin/rubocop -f github` |
| ERB lint | `bundle exec erb_lint ./app/**/*.erb` |
| JS/CSS lint | `npm run lint` |
| Format check | `npm run format:check` |
| Security scan | `bin/brakeman --no-pager` |
| OpenAPI docs | `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize` |
| Design tokens | `npm run tokens:check` |
| Multi-company bootstrap tests | `bin/rails test TEST=test/services/platform_bootstrap/multi_company_owners_test.rb` |

## External References
| Need | File |
| --- | --- |
| Project overview | `README.md` |
| Docker hosting | `docs/hosting/docker.md` |
| Railway deployment | `docs/superpowers/plans/2026-06-10-sure-railway-deployment.md` |
| Multi-company bootstrap | `docs/superpowers/plans/2026-06-10-multi-company-bootstrap.md` |
| Bootstrap spec | `docs/superpowers/specs/2026-06-10-multi-company-bootstrap-design.md` |
| API checklist | `.cursor/rules/api-endpoint-consistency.mdc` |
| UI conventions | `.cursor/rules/project-design.mdc` |
| View conventions | `.cursor/rules/view_conventions.mdc` |
| Stimulus conventions | `.cursor/rules/stimulus_conventions.mdc` |
| Securities providers | `docs/llm-guides/adding-a-securities-provider.md` |
| CI workflow | `.github/workflows/ci.yml` |

## Key Conventions
- Use Minitest and fixtures for behavioral tests; keep rswag specs documentation-only.
- API endpoint changes need matching Minitest coverage and regenerated `docs/api/openapi.yaml`.
- UI work should use `DS::*` components, `icon`, `t()`, and tokens from `app/assets/tailwind/sure-design-system.css`.
- Do not hand-edit generated token output; regenerate with `npm run tokens:build`.
- Bootstrap passwords for `platform_bootstrap:multi_company_owners` must come from hidden prompts or one-shot env vars only.
- Railway production work must confirm project, environment, and service before mutation.
- Provider metadata belongs in `Transaction#extra`, namespaced by provider.
- Pending support: SimpleFIN uses upstream `pending` or blank/0 `posted` with `transacted_at`; Plaid uses `extra["plaid"]["pending"]`; Lunchflow uses `extra["lunchflow"]["pending"]`; manual/CSV imports have no pending state.
- SimpleFIN FX metadata uses `extra["simplefin"]["fx_from"]` and `extra["simplefin"]["fx_date"]`; SimpleFIN/Lunchflow pending and raw debug behavior are default-off ENV toggles in their initializers.
