# Repository Guidelines

## Project Structure & Module Organization
- Code: `app/` (Rails MVC, services, jobs, mailers, components), JS in `app/javascript/`, styles/assets in `app/assets/` (Tailwind, images, fonts).
- Config: `config/`, environment examples in `.env.local.example` and `.env.test.example`.
- Data: `db/` (migrations, seeds), fixtures in `test/fixtures/`.
- Tests: `test/` mirroring `app/` (e.g., `test/models/*_test.rb`).
- Tooling: `bin/` (project scripts), `docs/` (guides), `public/` (static), `lib/` (shared libs).
- Ruby version: Defined in `.ruby-version` (currently 3.4.7).
- Key dependencies: Rails 7.2, PostgreSQL, Redis, Sidekiq, Stimulus, Turbo, Tailwind.

## Build, Test, and Development Commands
- Setup: `cp .env.local.example .env.local && bin/setup` — install deps, set DB, prepare app.
- Run app: `bin/dev` — starts Rails server and asset/watchers via `Procfile.dev`.
- Test suite: `bin/rails test` — run all Minitest tests; add `TEST=test/models/user_test.rb` to target a file.
- Run single test: `bin/rails test test/models/user_test.rb:17` — runs specific test line.
- Lint Ruby: `bin/rubocop` — style checks; add `-A` to auto-correct safe cops.
- Lint/format JS/CSS: `npm run lint` and `npm run format` — uses Biome.
- Run coverage: `COVERAGE=true bin/rails test` — generates SimpleCov coverage report.
- Security scan: `bin/brakeman` — static analysis for common Rails issues.
- Database: `bin/rails db:migrate`, `bin/rails db:rollback`, `bin/rails db:seed`.

## Ruby Code Style & Conventions
- Indentation: 2 spaces (enforced by rubocop-rails-omakase).
- Quotes: Double quotes for all strings (enforced by erb-lint and rubocop).
- Naming: `snake_case` for methods/variables, `CamelCase` for classes/modules.
- File structure: Follow Rails conventions (models in `app/models`, controllers in `app/controllers`, etc.).
- Constants: Use `SCREAMING_SNAKE_CASE` for module/class constants; freeze with `.freeze`.
- Private methods: Keep private methods at bottom, indented 2 levels, comment groups.
- Error handling: Use `raise` for exceptions, `redirect_to ... alert:` for user-facing errors in controllers.
- Database: Use `find_by!` for not-found errors expected, `find_by` for optional returns.
- Validations: Place after associations, before callbacks and custom methods.
- Callbacks: Group together before private methods, specify `if`/`unless` conditions clearly.
- Service objects: Use for complex business logic; name with verb (e.g., `UserDeleter`, `TransactionImporter`).

## JavaScript Code Style & Conventions
- Framework: Stimulus controllers for interactive components, imported via importmap.
- Formatting: Use Biome (runs `biome format --write`) — automatically formats on save.
- Quotes: Double quotes for all strings.
- Naming: `lowerCamelCase` for variables/functions, `PascalCase` for classes/components.
- Private methods: Use private class fields with `#` prefix (e.g., `#privateMethod() { ... }`).
- Controller targets: Define with `static targets = [...]` and access via `this.targetNameTarget`.
- Lifecycle hooks: `connect()` and `disconnect()` for setup/teardown; use `disconnect` for cleanup.
- Arrow functions: Prefer arrow functions for callbacks and anonymous functions.
- DOM manipulation: Use Stimulus targets and actions over direct DOM queries where possible.

## Testing Guidelines
- Framework: Minitest (Rails). Name files `*_test.rb` and mirror `app/` structure.
- Run: `bin/rails test` locally and ensure green before pushing.
- Fixtures: Use `test/fixtures` (all fixtures auto-loaded with `fixtures :all`).
- HTTP mocking: Use VCR cassettes in `test/vcr_cassettes`; sensitive data filtered in `test/test_helper.rb`.
- Test structure: `setup` method for common setup, `test "description"` blocks for assertions.
- Assertions: Use `assert`, `refute`, `assert_equal`, `assert_raises` as appropriate.
- Parallelization: Tests run in parallel by default; set `DISABLE_PARALLELIZATION=true` to disable.
- Test organization: Group related tests with descriptive comments; keep tests focused and isolated.
- Mocking: Use Mocha for mocking/stubbing; prefer real objects over mocks when possible.
- Controller tests: Use `sign_in(user)` helper (defined in test_helper) for authentication setup.

## Database & Schema Conventions
- Migrations: Use `change` method for reversible migrations; use `up`/`down` only when necessary.
- Indexes: Always add indexes for foreign keys (e.g., `add_reference :posts, :user, index: true`).
- Columns: Use appropriate types (e.g., `datetime` for timestamps, `text` for long strings).
- Defaults: Set sensible defaults in migrations rather than application code.
- Polymorphic: Use `references` with `polymorphic: true` for polymorphic associations.

## Imports & Dependencies
- Ruby: Group standard lib, then gems, then local requires. Use `require_relative` for app internals.
- JavaScript: ES6 imports via importmap; import from npm packages first, then app modules.
- Gem ordering: Alphabetize, group by type (rails, database, external, internal), use `~>` for version constraints.
- Avoid circular dependencies; use dependency injection or service objects when needed.
- Gemfile: Keep gems alphabetized within groups; use `require: false` for optional gems.

## Commit & Pull Request Guidelines
- Commits: Imperative subject ≤ 72 chars (e.g., "Add account balance validation"). Include rationale in body and reference issues (`#123`).
- PRs: Clear description, linked issues, screenshots for UI changes, and migration notes if applicable. Ensure CI passes, tests added/updated, and `rubocop`/Biome are clean.

## Security & Configuration Tips
- Never commit secrets. Start from `.env.local.example`; use `.env.local` for development only.
- Run `bin/brakeman` before major PRs. Prefer environment variables over hard-coded values.
- Rate limiting: Use `ApiRateLimiter` for API endpoints; `NoopApiRateLimiter` for self-hosted mode.
- Authentication: Use Pundit policies for authorization; `before_action` for filters.
- Passwords: Use `has_secure_password` with `validations: false` for SSO-only users.
- OAuth/API: Configure providers in `config/initializers/` for SimpleFIN, Plaid, Lunchflow, Coinbase.

## Common Patterns & Best Practices
- Use transactions for multi-step database operations to ensure atomicity.
- Implement pagination with `pagy` for index actions and list views.
- Use Rails time helpers (`1.day.ago`, `Time.current`) instead of `Time.now`.
- Prefer `ActiveSupport::Duration` (e.g., `15.minutes`) over integer seconds.
- Use I18n for all user-facing strings via `t()` helper.
- Implement rescue_from in controllers for standardized error handling.
- Use strong parameters with `permit()` to whitelist form inputs.
- Add database indexes for foreign keys and frequently queried columns in migrations.
- Background jobs: Use Sidekiq for async tasks; define jobs in `app/jobs/` with `perform` method.
- State machines: Use AASM for model state management; define states, events, and transitions clearly.
- Components: Use ViewComponent for reusable UI; inherit from `ApplicationComponent` or `DesignSystemComponent`.

## API Development Guidelines

### OpenAPI Documentation (MANDATORY)
When adding or modifying API endpoints in `app/controllers/api/v1/`, you **MUST** create or update corresponding OpenAPI request specs for **DOCUMENTATION ONLY**:

1. **Location**: `spec/requests/api/v1/{resource}_spec.rb`
2. **Framework**: RSpec with rswag for OpenAPI generation
3. **Schemas**: Define reusable schemas in `spec/swagger_helper.rb`
4. **Generated Docs**: `docs/api/openapi.yaml`
5. **Regenerate**: Run `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize` after changes

## Providers: Pending Transactions and FX Metadata (SimpleFIN/Plaid/Lunchflow)

- Pending detection
  - SimpleFIN: pending when provider sends `pending: true`, or when `posted` is blank/0 and `transacted_at` is present.
  - Plaid: pending when Plaid sends `pending: true` (stored at `transaction.extra["plaid"]["pending"]` for bank/credit transactions imported via `PlaidEntry::Processor`).
  - Lunchflow: pending when API returns `isPending: true` in transaction response (stored at `transaction.extra["lunchflow"]["pending"]`).
- Storage (extras)
  - Provider metadata lives on `Transaction#extra`, namespaced (e.g., `extra["simplefin"]["pending"]`).
  - SimpleFIN FX: `extra["simplefin"]["fx_from"]`, `extra["simplefin"]["fx_date"]`.
- UI
  - Shows a small "Pending" badge when `transaction.pending?` is true.
- Variability
  - Some providers don't expose pendings; in that case nothing is shown.
- Configuration (default-off)
  - SimpleFIN runtime toggles live in `config/initializers/simplefin.rb` via `Rails.configuration.x.simplefin.*`.
  - Lunchflow runtime toggles live in `config/initializers/lunchflow.rb` via `Rails.configuration.x.lunchflow.*`.
  - ENV-backed keys:
    - `SIMPLEFIN_INCLUDE_PENDING=1` (forces `pending=1` on SimpleFIN fetches when caller didn't specify a `pending:` arg)
    - `SIMPLEFIN_DEBUG_RAW=1` (logs raw payload returned by SimpleFIN)
    - `LUNCHFLOW_INCLUDE_PENDING=1` (forces `include_pending=true` on Lunchflow API requests)
    - `LUNCHFLOW_DEBUG_RAW=1` (logs raw payload returned by Lunchflow)

### Provider support notes

- SimpleFIN: supports pending + FX metadata; stored under `extra["simplefin"]`.
- Plaid: supports pending when the upstream Plaid payload includes `pending: true`; stored under `extra["plaid"]`.
- Plaid investments: investment transactions currently do not store pending metadata.
- Lunchflow: supports pending via `include_pending` query parameter; stored under `extra["lunchflow"]`.
- Manual/CSV imports: no pending concept.

## Additional Notes

- Ruby version: Defined in `.ruby-version` (currently 3.4.7).
- Rails version: 7.2.2 (see Gemfile).
- Always run `bin/rubocop` and `npm run lint` before committing.
- When adding new features, ensure tests are added or updated.
- Database migrations should be reversible; test with `bin/rails db:rollback`.
- Use `rails console` for debugging in development environment.
