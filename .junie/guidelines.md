# Junie Project Guidelines for Sure

These are the working rules for Junie when contributing to this repository. Follow them for analysis, coding, linting, testing, and PR etiquette.

## Overview
- Backend: Ruby on Rails (PostgreSQL), Sidekiq/Redis
- Frontend: Hotwire (Turbo/Stimulus), TailwindCSS v4 (Propshaft assets)
- Icons: Lucide via `icon` helper
- Integrations: Stripe (payments), Plaid, SimpleFin, OpenAI
- Tests: Minitest + fixtures
- App modes: `managed` and `self_hosted` (via `Rails.application.config.app_mode`)

## Local development
1) Setup
- Ensure Ruby per `.ruby-version`, Postgres, and Redis installed
- Commands:
  - cd sure
  - cp .env.local.example .env.local
  - bin/setup
  - bin/dev (visit http://localhost:3000; demo: user@example.com / Password1!)

2) Optional demo data
- rake demo_data:default

## Running app/services
- Use `bin/dev` (per `Procfile.dev`). Do not run `rails server` directly (prohibited).

## Testing policy
- Framework: Minitest
- Commands:
  - Run all: `bin/rails test`
  - Single file: `bin/rails test test/models/account_test.rb`
  - Directory: `bin/rails test test/controllers`
- When to run tests:
  - If Ruby code or templates change: run the most relevant subset; expand as needed
  - If only docs/comments change: do not run tests

## Linting and formatting (required; CI-enforced)
- RuboCop is enforced by CI (`bin/rubocop -f github`)
- Before committing/pushing:
  - Run `bin/rubocop -A` for auto-corrections, then `bin/rubocop` to verify clean
- Key cops observed in this repo (follow strictly):
  - Layout/IndentationWidth: 2 spaces
  - Layout/EndAlignment: align `end` with its keyword
  - Layout/SpaceInsideArrayLiteralBrackets: spaces inside brackets: `[ :a, :b ]`
  - Layout/SpaceAfterComma: `a, b` (add a space after commas)
  - Layout/SpaceBeforeBlockBraces: `arr.map { |x| x }` (space before `{`)
  - Layout/EmptyLineAfterMagicComment: blank line after `# frozen_string_literal: true`
  - Layout/IndentationConsistency: keep consistent 2-space indentation
  - Style/TrailingCommaInHashLiteral: avoid trailing comma on last item
  - Style/RedundantReturn: remove redundant `return` when last expression
- If CI flags anything, prefer stylistic fixes over disabling cops

## Data & migrations
- PostgreSQL is primary DB
- Migrations must inherit from `ActiveRecord::Migration[7.2]`
- Do not auto-run migrations in assistant responses
- On merge/rebase conflicts in `db/schema.rb`: keep base schema, finish rebase, run `bin/rails db:migrate` to regenerate, then commit the updated `schema.rb`

## Coding conventions
- Prefer "skinny controllers, fat models"; business logic in `app/models` using POROs and concerns
- Prefer model instance methods over service objects
- Use `Current.user` and `Current.family` for request scoped context (never `current_user`/`current_family`)
- Ignore adding i18n wiring for new changes unless explicitly requested; hardcode strings in English
- Optimize for clarity; watch out for N+1s and heavy payloads in global layouts

## Frontend/UI rules
- Tailwind v4 with custom tokens in `app/assets/tailwind/maybe-design-system.css`
  - Use functional tokens: `text-primary`, `bg-container`, `border-primary`, etc.; do not invent new tokens without approval
- Prefer semantic HTML and native elements
  - `<dialog>` for modals; `<details><summary>` for disclosures
- Use Turbo frames/streams; prefer URL query params for state when possible
- Always use `icon` helper from `app/helpers/application_helper.rb` (never call `lucide_icon` directly)
- Format numbers/dates/currencies server‑side; JS should enhance display only

## SimpleFin/Plaid conventions (high level)
- De‑duplication of SimpleFin accounts by upstream `account_id`
- Auto-open relink modal by redirecting with `open_relink_for` param to Accounts page
- Idempotent transfer matching (`find_or_create_by!` + `RecordNotUnique` rescue)
- Avoid creating provider-linked accounts in “balances-only” discovery; only update balances for linked accounts

## Project structure anchors
- Design tokens: `app/assets/tailwind/maybe-design-system.css`
- Helpers: `app/helpers/application_helper.rb`
- Conventions/architecture/UI rules: `.cursor/rules/*`

## Prohibited actions for assistants
- Do not run `rails server`
- Do not run `touch tmp/restart.txt`
- Do not run `rails credentials`
- Do not auto-run migrations

## When to build/run
- Run app: only when explicitly asked to launch or verify runtime behavior
- Build assets: not needed explicitly in dev (handled by `bin/dev`)

## PR etiquette
- Keep diffs minimal and focused
- Include a short “What changed and why,” and a manual test plan
- Ensure RuboCop and targeted tests pass before marking ready for review
