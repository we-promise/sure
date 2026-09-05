# Repository Guidelines

## Maintaining Agent Guidance

`AGENTS.md` is the source of truth for shared repository guidance. `CLAUDE.md` is a relative symlink to `AGENTS.md`, so changes to shared guidance must be made here and remain synchronized through that link. Do not replace the symlink with a separately maintained copy.

Intentional tool-specific differences are limited to how guidance is loaded:

- Codex reads `AGENTS.md`; Claude Code reads the same content through `CLAUDE.md`. There are no separate Claude-specific repository rules.
- `.github/copilot-instructions.md` directs Copilot to this file. Keep that entry point short and free of duplicated shared rules.
- Cursor reads the root `AGENTS.md`. Its `.cursor/rules/*.mdc` files only select when to load shared guides from `docs/llm-guides/`; their frontmatter and `@` references are Cursor-specific, not separate repository policy.
- Current Junie versions read the root `AGENTS.md`; `.junie/guidelines.md` points here for versions or IDE settings that still use that legacy path. Do not create `.junie/AGENTS.md`, which would take precedence over the shared root file.

Keep detailed, task-specific guidance in shared `docs/llm-guides/` files and link it here. Tool entry points must reference that content instead of copying it. Label any future tool-specific behavior with the tool and the reason it differs.

Verify guidance changes against the current code, scripts, and tests, not just the other instruction files. Check that `test -L CLAUDE.md`, `readlink CLAUDE.md` (expected: `AGENTS.md`), and `cmp AGENTS.md CLAUDE.md` succeed. Use a checkout that preserves symlinks; if a client materializes the link as a plain file containing `AGENTS.md`, restore the symlink rather than editing that file as guidance.

## Project Structure and Architecture

- Rails code lives in `app/`: models, controllers, jobs, mailers, components, and views. Prefer models, concerns, and POROs for business logic; keep controllers thin.
- JavaScript lives in `app/javascript/`; component-specific Stimulus controllers can live alongside components in `app/components/`. Styles and assets live in `app/assets/`.
- Configuration lives in `config/`, with environment examples in `.env.local.example` and `.env.test.example`. Database migrations and schema live in `db/`.
- Behavioral tests live in `test/`, mirroring `app/`; fixtures are in `test/fixtures/`, VCR cassettes in `test/vcr_cassettes/`, and helpers in `test/support/`.
- API documentation specs live in `spec/requests/api/v1/`. Tooling and guides live in `bin/`, `docs/`, and `lib/`.
- `Family` owns users and financial accounts. `Account` belongs to a family, has a delegated `accountable` type, and owns `Entry` records. Entries delegate to `Transaction`, `Trade`, or `Valuation`; investment accounts also have holdings and securities.
- Accounts and entries store their own currency. Use `Money` and historical `ExchangeRate` records for conversion and reporting in the family's preferred currency; do not assume stored amounts already use that currency.
- The app supports `managed` and `self_hosted` modes through `Rails.application.config.app_mode`. Providers are optional and configured through provider settings/registry code.
- Hotwire (Turbo and Stimulus), ViewComponent, Tailwind CSS, and D3 power the web UI. Sidekiq/Redis handle background work such as `SyncJob`, `ImportJob`, and `AssistantResponseJob`; sidekiq-cron schedules recurring jobs.
- Provider integrations fetch and normalize data through their importers/processors; `Sync` records track sync operations. Manual imports use `Import` and its subclasses. Follow the relevant provider path rather than assuming all integrations behave like Plaid.
- Web authentication uses sessions. API v1 supports Doorkeeper OAuth and `X-Api-Key` authentication; API keys are not JWTs. API-key rate limits use `ApiRateLimiter`.

For financial data changes, read the shared [architecture guide](docs/llm-guides/architecture.md) for account access, entry signs, balances, transfers, syncs, and provider entry points.

## Build, Test, and Development Commands

Use the commands appropriate to the task. Setup modifies the local database, clears logs/temp files, and restarts the application; do not run it as a routine verification step. Do not start servers, touch `tmp/restart.txt`, run `rails credentials`, or automatically apply migrations as part of an unrelated change.

| Task | Command / notes |
| --- | --- |
| Initial setup | Copy `.env.local.example` to `.env.local` if needed, then `bin/setup` (installs Ruby/npm dependencies, builds tokens, prepares the database) |
| Development server | `bin/dev` starts Rails, Sidekiq, and the Tailwind watcher via `Procfile.dev` |
| Rails console | `bin/rails console` |
| Unit/integration tests | `bin/rails test` |
| Specific test | `bin/rails test test/models/account_test.rb` (append `:42` to select a test by line) |
| System tests | `DISABLE_PARALLELIZATION=true bin/rails test:system` |
| Ruby lint | `bin/rubocop` (`-a` applies safe autocorrections; `-A` also includes unsafe corrections) |
| ERB lint | `bundle exec erb_lint path/to/view.html.erb` (configuration: `.erb_lint.yml`) |
| JavaScript lint/format | `npm run lint`, `npm run format:check`; `npm run lint:fix` / `npm run format` write changes |
| Design tokens | `npm run tokens:build` / `npm run tokens:check` |
| Security | `bin/brakeman --no-pager`; `bin/importmap audit` for JavaScript dependencies |
| Database maintenance | `bin/rails db:prepare`, `db:migrate`, `db:rollback`, or `db:seed`, only as required by the task |

Biome currently targets `app/javascript/**/*.js` via `biome.json`; these npm commands do not lint CSS or every component-local controller.

### System Tests in the Dev Container

The Dev Container sets `SELENIUM_REMOTE_URL` to its `selenium/standalone-chromium` service. System tests use that remote browser, so local Chrome is unnecessary. Run `DISABLE_PARALLELIZATION=true bin/rails test:system`. Watch at `http://localhost:7900` or inspect Selenium at `http://localhost:4444` (default noVNC password: `secret`).

### Before a Pull Request

Run `bin/rails test`, Ruby lint (`bin/rubocop -f github`), and `bin/brakeman --no-pager` before opening a code PR. Run system tests when relevant to the user flow, ERB lint for affected templates, and Biome for affected JavaScript. Review autocorrections rather than applying them across unrelated files. Ensure the applicable CI checks pass before requesting review; report any check you could not run and why.

For documentation-only changes, verify the documented commands, paths, links, and symlink integrity and run `git diff --check`. When changing API guidance, also run `ruby test/support/verify_api_endpoint_consistency.rb`.

## Coding and Testing Conventions

- Ruby: two-space indentation, `snake_case` methods/variables, `CamelCase` classes/modules. Follow Rails naming and the existing RuboCop configuration.
- JavaScript: `lowerCamelCase` variables/functions and `PascalCase` classes/components. Use Biome formatting within its configured scope.
- Use `Current.user` and `Current.family` for request context, not `current_user` / `current_family`.
- Prefer Rails capabilities and established dependencies. New dependencies need a concrete technical or business reason.
- Organize business logic in model concerns and POROs, avoiding new service-object layers. Models should answer questions about themselves, such as `account.balance_series`.
- Enforce simple constraints (nullability, uniqueness) in the database; keep complex validations and business logic in ActiveRecord. Avoid N+1 queries and expensive work in global layouts; use background jobs for heavy work.
- For new migrations, use the compatibility version emitted by the current Rails generator. Preserve existing migrations' compatibility versions; do not rewrite them just to match the current framework.
- Use Minitest, fixtures, Mocha, and VCR for behavioral tests. RSpec/rswag is the documentation-only exception described below; do not introduce RSpec behavioral tests or FactoryBot.
- Name tests `*_test.rb` and mirror `app/`. Keep base fixtures small, create edge cases in the test, and use existing helpers/cassettes.
- Write focused tests for important behavior and boundaries. Assert query results and command interactions without testing another class's internals or ActiveRecord itself. Use system tests sparingly for critical user flows; mock only what is needed.

## Frontend, Components, and Internationalization

- Prefer semantic HTML, Turbo Frames/Streams, and server-side formatting. Use URL query parameters for UI state where practical.
- Reuse `DS::*` components before building markup. Use ViewComponents for reusable or complex UI (variants, slots, interaction, accessibility); use partials for simple, mostly static content. Keep domain logic out of templates.
- Use declarative Stimulus `data-action` bindings and `data-*-value` attributes instead of inline JavaScript. Keep controllers small and focused, with a clear public API.
- Keep component-local Stimulus controllers encapsulated in their component templates. Put controllers reused across views in `app/javascript/controllers/`, and prefer Stimulus targets to document-wide DOM lookups.
- All user-facing strings use `t()`. Add hierarchical keys in the relevant feature's `config/locales/**/en.yml`, following adjacent files; use interpolation and Rails pluralization for dynamic text.
- Lookbook is mounted at `/design-system` outside production for component previews.

### Design System Hygiene (UI PRs)

When a PR touches `.erb`, view components, or `.css`:

1. **Tokens, not palette.** Use functional tokens from `app/assets/tailwind/sure-design-system.css` (`bg-warning/10`, `text-destructive`, `bg-container`, `text-primary`, `border-primary`). No raw Tailwind palette (`bg-blue-50`, `text-red-500`, hex literals).
2. **Reach for `DS::*` first.** Check `app/components/DS/` (`DS::Alert`, `DS::Button`, `DS::Disclosure`, `DS::Dialog`, `DS::Menu`, etc.) before writing an alert, badge, button, disclosure, dialog, or input shape.
3. **Two copies → lift to DS.** Same hand-rolled shape ≥2× in a diff with no DS equivalent → propose a new `DS::*` primitive before the second copy lands.
4. **Conventions.** Use the `icon` helper (never `lucide_icon` directly), no raw SVG outside DS primitives, user-facing strings via `t()`, avoid arbitrary `*-[Npx]` values when a scale token fits.

Reviewers escalate violations of (2)–(3) to close/rewrite; (1) and (4) are request-changes.

Design tokens originate in `design/tokens/sure.tokens.json`; `app/assets/tailwind/sure-design-system/_generated.css` is generated. For an approved token change, edit the JSON source, run `npm run tokens:build`, and include the generated output. Do not hand-edit generated CSS or introduce new global design-system styles without approval.

## API Development Guidelines

### OpenAPI Documentation (MANDATORY)

When adding or modifying endpoints in `app/controllers/api/v1/`, create or update corresponding OpenAPI request specs for **documentation only**:

1. **Location:** `spec/requests/api/v1/{resource}_spec.rb`.
2. **Framework:** RSpec with rswag for OpenAPI generation.
3. **Schemas:** Define reusable schemas in `spec/swagger_helper.rb`.
4. **Generated docs:** `docs/api/openapi.yaml`.
5. **Regenerate:** `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize`.

### Post-commit API consistency

After every API endpoint commit, ensure:

1. **Minitest behavioral coverage:** Update `test/controllers/api/v1/{resource}_controller_test.rb`. Use API keys and `api_headers` (`X-Api-Key`); cover the relevant successful actions and 401/403/404/422 failures.
2. **rswag docs-only:** No `expect(...)`, `assert_*`, or custom behavioral assertion blocks in `spec/requests/api/v1/`. Use `run_test!` to document request/response shapes.
3. **Consistent rswag authentication:** Use `ApiKey.generate_secure_key`, `ApiKey.create!(...)`, and `let(:'X-Api-Key') { api_key.plain_key }`. Do not switch these documentation specs to OAuth/Bearer just because the application also supports OAuth.

Full checklist and example: [API endpoint consistency](docs/llm-guides/api-endpoint-consistency.md). Verify the guidance with `ruby test/support/verify_api_endpoint_consistency.rb`; add `--compliance` to report current API coverage/auth/documentation violations.

## Securities Providers

When adding a securities price provider (Tiingo, EODHD, Binance-style crypto, etc.), follow [adding a securities provider](docs/llm-guides/adding-a-securities-provider.md) for the provider class, registry wiring, MIC handling, settings UI, locales, and tests.

## Providers: Pending Transactions and FX Metadata

Provider metadata belongs on `Transaction#extra` under the provider namespace. `Transaction#pending?` controls the Pending badge; see `Transaction::PENDING_PROVIDERS` for the current supported namespaces. The three integrations below have different configuration and import behavior.

### SimpleFIN

- `SimplefinEntry::Processor.pending?` accepts a truthy explicit `pending` flag, or `posted` exactly `0` / `"0"` with a positive `transacted_at`. Missing/blank `posted` alone does **not** imply pending.
- Store pending in `extra["simplefin"]["pending"]`. When transaction and account currencies differ, `fx_from` records the transaction currency and `fx_date` prefers `transacted_at`, falling back to the posted date.
- Pending inclusion defaults on. Fetch precedence in `SimplefinItem::Importer` is explicit `pending:` argument, then a nonblank `SIMPLEFIN_INCLUDE_PENDING` override, then `Setting.syncs_include_pending`.
- `Provider::Simplefin#get_accounts` sends `pending=1` only when enabled and otherwise omits the parameter; do not send `pending=0` (some bridges check only its presence). The client itself does not resolve the setting.
- The entry processor also checks the environment override/shared setting and skips pending entries when disabled, including transactions already stored in raw payloads.
- Runtime environment configuration: `config/initializers/simplefin.rb` → `Rails.configuration.x.simplefin.*`.

### Plaid

- Bank/credit transactions use the upstream `pending` flag. `PlaidEntry::Processor` stores `extra["plaid"]["pending"]` and `pending_transaction_id` for pending-to-posted reconciliation. Investment transaction processors do not currently store pending metadata.
- Pending inclusion defaults on. A nonblank `PLAID_INCLUDE_PENDING` overrides `Setting.syncs_include_pending`.
- `PlaidAccount::Transactions::Processor` filters pending added/modified transactions when disabled; the setting does **not** prevent Plaid from returning them in API responses.
- Runtime environment configuration: `config/initializers/plaid_config.rb` → `Rails.configuration.x.plaid.*`.

### Lunchflow

- `LunchflowEntry::Processor` maps `isPending` to `extra["lunchflow"]["pending"]` when the field is present.
- Pending fetching defaults **off**. `LUNCHFLOW_INCLUDE_PENDING=1` enables the `include_pending=true` request parameter; this is independent of `Setting.syncs_include_pending`.
- This flag controls fetching, not a separate processor filter for cached pending payloads.
- Runtime configuration: `config/initializers/lunchflow.rb` → `Rails.configuration.x.lunchflow.*`.

Use `0` / `1` for the pending environment overrides. SimpleFIN and Plaid share `Setting.syncs_include_pending` when their own override is absent; that setting defaults true with neither environment variable set, but its initial default also considers both environment variables (see `app/models/setting.rb`). Do not infer live behavior from initializer defaults alone. Manual/CSV imports do not provide provider pending metadata.

### Debug Logging for Provider Syncs

When a provider sync/import path hits a recoverable error or suspicious partial response that support may need later, prefer `DebugLogEntry.capture(...)` over `Rails.logger.*`.

- Record support-relevant diagnostics in the debug log so they surface in the super-admin `/settings/debug` UI.
- Include `category`, `level`, `message`, `source`, `provider_key`, and useful structured `metadata`. Attach `family` and `account_provider` when available for filtering and tracing.
- Reserve raw Rails logging for low-value local noise. Do not put credentials or unnecessary personal data in diagnostic metadata.
- Raw payload logging defaults off: `SIMPLEFIN_DEBUG_RAW=1` and `LUNCHFLOW_DEBUG_RAW=1` enable their respective dumps. `UP_DEBUG_RAW=1` is additionally gated by `Rails.env.local?` in `UpItem::Importer`; that restriction must not be assumed for the other providers. Raw dumps can contain sensitive financial data.

## Commits, Pull Requests, and Security

- Make small, cohesive commits with imperative subjects ≤72 characters; explain the rationale and reference relevant issues.
- Target `main`. PR descriptions should explain the problem and resulting behavior, link issues, and include validation, UI screenshots, and migration notes where applicable.
- Never commit secrets. Use environment variables and local `.env` files based on the examples; keep credentials out of code and fixtures.
