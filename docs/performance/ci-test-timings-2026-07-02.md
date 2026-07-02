# CI Test Performance Audit — 2026-07-02

This report documents the response times of the operations exercised by the CI
unit/integration suite (`bin/rails test`, the `test_unit` job in
`.github/workflows/ci.yml`), identifies the 10 slowest flows, and lists the
performance PRs derived from it.

## Methodology

- Full suite run: `bin/rails test -v` (verbose per-test wall times), Postgres 16 +
  Redis, parallel workers = number of processors.
- Per-request breakdown: an `ActiveSupport::Notifications` probe subscribed to
  `process_action.action_controller` (db/view runtime per request),
  `sql.active_record` (query counts) and `render_partial/collection/template.action_view`
  (per-partial cumulative render cost) while re-running the slowest suites serially.

## Headline numbers

| Metric | Value |
|---|---|
| Tests | 5,277 runs / 21,735 assertions |
| Wall time (parallel) | 156.2s |
| Accumulated test time | 577.6s |
| Result | green (4 failures observed locally were caused by `ANTHROPIC_*` env vars present in the audit environment, not by the code) |

## Slowest individual operations (top 25 of 5,277)

| Time | Test (operation) |
|---|---|
| 16.78s | `Provider::SimplefinTest#test_raises_SimplefinError_after_max_retries_exceeded` |
| 3.07s | `AssistantTest#test_external_assistant_adds_error_on_connection_failure` |
| 3.01s | `Assistant::External::ClientTest#test_retries_transient_errors_then_raises` |
| 2.36s | `Family::FinancialDataResetTest#test_destructive_reset_preserves_financial_data_for_other_families` |
| 2.31s | `Provider::SimplefinTest#test_retries_on_Net::ReadTimeout_and_succeeds_on_retry` |
| 2.25s | `Provider::SimplefinTest#test_retries_on_SocketError_and_succeeds_on_retry` |
| 2.14s | `Provider::SimplefinTest#test_retries_on_Net::OpenTimeout_and_succeeds_on_retry` |
| 1.51s | `Api::V1::ImportSessionsControllerTest#test_uploads_ordered_chunks…` |
| 1.46s | `TransactionsControllerTest#test_can_paginate` |
| 1.41s | `Family::FinancialDataResetTest#test_destructive_reset_clears_financial_data…` |
| 1.36s | `SimplefinItemsControllerTest#test_dismissing_a_replacement_suggestion…` |
| 1.23s | `UsersControllerTest#test_admin_can_reset_family_data_and_load_sample_data` |
| 1.19s | `AccountsControllerTest#test_statements_tab_filters_historical_coverage_by_year` |
| 1.17s | `CreditCardsControllerTest#test_shows_new_form` |
| 1.17s | `TransactionsControllerTest#test_pagination_does_not_duplicate_or_skip…` |
| 1.16s | `UsersControllerTest#test_admin_can_reset_family_data` |
| 1.13s | `FamilyResetJobTest#test_resets_family_data_successfully` |
| 1.11s | `Admin::UsersControllerTest#test_index_groups_users_by_family…` |
| 1.10s | `Api::V1::BaseControllerTest#test_should_return_429_when_rate_limit_exceeded` |
| 1.08s | `FamilyResetJobTest#test_reset_leaves_another_family's_imports…` |
| 1.06s | `Assistant::HistoryTrimmerTest#test_keeps_full_history_when_budget_is_generous` |
| 1.05s | `Family::FinancialDataResetTest#test_destructive_reset_is_idempotent` |
| 1.05s | `Admin::UsersControllerTest#test_index_shows_subscription_status_for_families` |
| 1.05s | `SyncHourlyJobTest#test_continues_syncing_other_items_when_one_fails` |
| 1.03s | `ReportsControllerTest#test_last_6_months_default_start_date_is_consistent…` |

## Slowest suites (top 20, by accumulated time)

| Total | Tests | Avg | Suite |
|---|---|---|---|
| 23.48s | 10 | 2.35s | `Provider::SimplefinTest` |
| 19.38s | 37 | 0.52s | `TransactionsControllerTest` |
| 18.59s | 30 | 0.62s | `ReportsControllerTest` |
| 14.92s | 33 | 0.45s | `AccountsControllerTest` |
| 14.07s | 33 | 0.43s | `SimplefinItemsControllerTest` |
| 13.57s | 29 | 0.47s | `SnaptradeItemsControllerTest` |
| 11.99s | 39 | 0.31s | `SophtronItemsControllerTest` |
| 11.76s | 35 | 0.34s | `Settings::HostingsControllerTest` |
| 10.79s | 18 | 0.60s | `ActiveStorageAuthorizationTest` |
| 10.76s | 28 | 0.38s | `Settings::ProvidersControllerTest` |
| 10.06s | 23 | 0.44s | `GoalsControllerTest` |
| 9.71s | 27 | 0.36s | `AccountStatementsControllerTest` |
| 8.41s | 19 | 0.44s | `ImportsControllerTest` |
| 7.76s | 22 | 0.35s | `TradesControllerTest` |
| 7.61s | 18 | 0.42s | `Transactions::CategorizesControllerTest` |
| 7.47s | 15 | 0.50s | `PropertiesControllerTest` |
| 7.43s | 15 | 0.50s | `MfaControllerTest` |
| 7.27s | 24 | 0.30s | `BrexItemsControllerTest` |
| 6.44s | 18 | 0.36s | `CategoriesControllerTest` |
| 6.42s | 11 | 0.58s | `UsersControllerTest` |

## Measured per-request response times (controller operations)

From the notification probe (serial runs of the slowest suites):

| Operation | Avg DB | Avg view | Notes |
|---|---|---|---|
| `AccountsController#index` | 73ms | 307ms | page template alone ~340ms incl. group partials |
| `AccountsController#show` | 24ms | 299ms | |
| `SnaptradeItemsController#setup_accounts` | 19ms | 290ms | |
| `ReportsController#index` | 65ms | 230ms | |
| `SimplefinItemsController#setup_accounts` | 15ms | 227ms | |
| `CreditCardsController#new` | 13ms | 220ms | modal form still renders full layout |
| `TransactionsController#new` | 20ms | 205ms | |
| `TransactionsController#index` | 28ms | 168ms | |
| `SessionsController#create` (sign in) | 3ms | — | **~230ms of bcrypt CPU, see below** |

## Root causes

1. **bcrypt cost-12 digests in `test/fixtures/users.yml`** — every `sign_in`
   (used by ~100 test files, roughly every controller/integration test) pays
   ~230ms of bcrypt verification CPU, regardless of
   `ActiveModel::SecurePassword.min_cost` (verification cost is embedded in the
   stored digest). This is the single largest contributor to suite time.
2. **Account sidebar is rendered twice per page** (desktop + hidden mobile copy in
   `layouts/application.html.erb`), and `DS::Tabs` renders all three tab panels
   (all/assets/debts), so each account group renders up to 6× per request:
   ~80ms × 2 per HTML page (measured 5.8s of the 54s in a 4-suite run).
   This is also a production cost on cache-cold renders.
3. **`Kernel.sleep` in provider retry backoff** (`Provider::Simplefin`,
   `Provider::Akahu`, `Provider::Up`) bypasses the tests' `stubs(:sleep)`, so
   retry tests really sleep (2s+4s+8s in the worst test: 16.78s).
4. **Assistant external client retries** use real 1s/2s sleeps in tests (~7s).
5. **API rate-limit tests** issue 100 real HTTP requests to exhaust the limiter
   instead of seeding the Redis counter (~1s per test, 4 tests).
6. **Family financial data reset** runs 33 `COUNT` queries twice (before/after)
   plus `destroy_all` cascades; the flow is exercised by 3 suites (~14s total).

## The 10 slowest flows and the PRs addressing them

| # | Flow (measured CI cost) | Fix |
|---|---|---|
| 1 | Sign-in operation, every authenticated flow (~230ms × ~2,000+ tests) | Regenerate fixture password digests at `BCrypt::Engine::MIN_COST` |
| 2 | SimpleFIN provider sync/retry (23.5s) | Make retry backoff sleep stubbable (`sleep` instead of `Kernel.sleep`) in SimpleFIN/Akahu/Up; stub missing sleeps in tests |
| 3 | Every HTML page render: account sidebar (~160ms/page view time) | Cut per-render cost of `accounts/_account_sidebar_tabs` and `_accountable_group` (batch per-account/per-group queries, avoid re-rendering groups per tab) |
| 4 | Transactions index (19.4s suite; 168ms view/req) | Reduce per-row partial/query cost in transactions list |
| 5 | Reports (18.6s suite; 65ms db + 230ms view/req) | Reduce IncomeStatement query volume and template cost |
| 6 | Accounts index/show (14.9s suite; ~300ms view/req) | Reduce per-account partial/query cost on the accounts page |
| 7 | Family financial data reset (~14s across 3 suites) | Collapse duplicate count queries; batch deletes where callback-free |
| 8 | SimpleFIN items management (14.1s suite; setup_accounts 227ms view) | Trim item partial / setup_accounts view cost |
| 9 | Assistant external retry (~7s) | Zero retry delay via injectable backoff config in test |
| 10 | API rate limiting (~4s) | Seed the Redis counter instead of issuing 100 requests per test |

Flows like SnapTrade/Sophtron/Hostings/Goals/Providers settings inherit most of
their cost from flows 1 and 3 (sign-in bcrypt + layout sidebar) and are covered
by those PRs.

## Resulting PRs

| # | PR | Fix |
|---|---|---|
| 1 | [#2551](https://github.com/we-promise/sure/pull/2551) | MIN_COST bcrypt digests in user fixtures |
| 2 | [#2552](https://github.com/we-promise/sure/pull/2552) | Stubbable provider retry backoff (SimpleFIN/Akahu/Up) |
| 3 | [#2553](https://github.com/we-promise/sure/pull/2553) | Memoize `Family#balance_sheet` + sync status lookups |
| 4 | [#2559](https://github.com/we-promise/sure/pull/2559) | Lazy-load the transactions filter menu |
| 5 | [#2560](https://github.com/we-promise/sure/pull/2560) | Skip layout for modal/drawer turbo frame requests |
| 6 | [#2561](https://github.com/we-promise/sure/pull/2561) | Batch reports trends chart into one month-grouped query |
| 7 | [#2562](https://github.com/we-promise/sure/pull/2562) | Skip data census in `FamilyResetJob` resets |
| 8 | [#2563](https://github.com/we-promise/sure/pull/2563) | Use eager-loaded syncs for provider item status |
| 9 | [#2564](https://github.com/we-promise/sure/pull/2564) | Stub assistant client retry backoff sleeps |
| 10 | [#2565](https://github.com/we-promise/sure/pull/2565) | Seed rate-limit counter instead of 100 requests/test |

## Verified combined result

All ten branches merged into one local integration branch and the full suite
re-run in the same environment:

| Metric | Before | After |
|---|---|---|
| Wall time (parallel) | 156.2s | **72.0s (-54%)** |
| Accumulated test time | 577.6s | **257.8s (-55%)** |
| Slowest single test | 16.78s | **2.58s** |
| Result | green | green (5,294 runs, 0 failures/errors) |
