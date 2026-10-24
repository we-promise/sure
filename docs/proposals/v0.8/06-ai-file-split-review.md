# Files to split in the AI / ML workflows

Which files the AI/ML workflows (01 W1–W23) depend on should become smaller files, and **when** relative to the workflow refactor ([02 §5](02-ai-architecture-review.md#5-suggested-sequencing) or the breaking-change option in [05](05-ai-breaking-change-option.md)).

> **Related PRs:** [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)* MCP-only scope · [#3990](https://github.com/we-promise/sure/issues/3990) · [#4157](https://github.com/we-promise/sure/issues/4157) · [#4147](https://github.com/we-promise/sure/issues/4147) MCP tool additions

Three tests decide whether a file should split:
- **F-H:** many PRs change the file, so parallel PRs collide on it.
- **F-M:** the file crosses MVC boundaries.
- **F-R:** the file isn't constrained to one resource.

[05 §5](05-ai-breaking-change-option.md#5-pulling-it-apart-for-review) lists the largest files by size. This document adds the evidence for *why* each one should split, and when.

## Contents

- [Findings](#findings)
- [How it was measured](#how-it-was-measured)
- [1. Merge hotspots (F-H)](#1-merge-hotspots-f-h)
- [2. Files crossing MVC boundaries (F-M)](#2-files-crossing-mvc-boundaries-f-m)
- [3. Files not constrained to one resource (F-R)](#3-files-not-constrained-to-one-resource-f-r)
- [4. When to split](#4-when-to-split)
- [5. Order](#5-order)

## Findings

- **Collisions concentrate in a handful of shared files.**
  - `config/routes.rb` is changed by 44 of the 330 open PRs.
  - `app/models/family.rb` by 20.
  - `config/locales/views/settings/en.yml` by 16.
  - `app/models/assistant.rb` by 14.
  - `settings/hostings_controller.rb` by 12.
  - Only `db/schema.rb` (73) is higher, and it can't be split.
- **A registry only helps parallel work when each entry is its own file.** `Assistant.function_classes` is one hand-written array of every chat and MCP tool, so it is a collision point, though the tools themselves are already one file each. This qualifies O-B7 in 02.
- **The settings pages put configuration logic in views.** The `settings/hostings` views read `ENV` 70 times to decide which value wins and whether a field is locked. That is where the web/worker drift in [01 D3](01-ai-ml-workflow-map.md#d3-process-placement-web-vs-worker) comes from.
- **AI availability is decided in helpers and controllers.**
  - `bills_helper`, `insights_helper` and `family_merchants_controller` each call `Provider::Registry` themselves.
  - `family_merchants_controller` checks only OpenAI, which is D4 #1 in 01.
- **Several files mix the AI step with the record it works on.**
  - `pdf_import.rb` (596 lines, 10 models).
  - `chat.rb` (307 lines, 10 models).
  - `imports_controller.rb`, which uploads vector documents synchronously.
  - `provider/openai.rb`, which holds chat transport and batch operations (939 lines).
- **Timing:** six splits should land **before** the refactor, nine **with** it, and five can happen **at any time**. Five files should not be split at all (§4).

## How it was measured

All on `main` @ `2250ba801`:
- **Churn:** commits touching the file from 2026-04-24 to 2026-10-23. That window has 1,433 commits on `main`.
- **Open PRs:** how many of the 330 PRs open on 2026-10-24 change the file. This is the closest available measure of merge-conflict exposure.
- **Resources:** distinct top-level `app/models` classes the file names. It's a heuristic: a name in a comment counts too.
- Line counts.

## 1. Merge hotspots (F-H)

| ID | File | Lines | Commits, 6 mo | Open PRs | Why PRs collide | Split |
|---|---|---|---|---|---|---|
| F-H1 | `config/routes.rb` | 1,044 | 95 | 44 | Every feature adds routes to the one file. It has no `draw` calls. | `draw(:settings)`, `draw(:api)`, `draw(:ai)`, … with `config/routes/*.rb` (built into Rails). Pure move. |
| F-H2 | `app/models/family.rb` | 938 | 47 | 20 | 13 `include` lines covering 24 `*Connectable` concerns, plus the AI/ML facade (`family.rb:174–592`, register I13). Bank-provider and AI PRs both edit it. | S10: `Family::Classification` (or `Enrichment`, BC11) for the AI/ML methods. Group the connectable includes into one `Family::Connectable` concern. |
| F-H3 | `config/locales/views/settings/en.yml` | 820 | 59 | 16 | One file holds 16 top-level sections, among them the AI pages `llm_usages`, `ai_prompts` and `mcp` and the debug page that resets the AI cache. Hostings, classifiers and five other pages already have their own folders (hostings: 23 commits, 9 open PRs), which shows the pattern works. | One file per settings page under `config/locales/views/settings/<page>/en.yml`. Rails already loads nested locale files here. |
| F-H4 | `app/models/assistant.rb` | 112 | 15 | 14 | `function_classes` is a hand-written array of every tool. Every new chat or MCP tool edits the same lines. Most of the 15 commits add tools or change which users see them (for example [#3990](https://github.com/we-promise/sure/issues/3990), [#4157](https://github.com/we-promise/sure/issues/4157), [#4147](https://github.com/we-promise/sure/issues/4147)). | Each tool registers itself (a `surfaces`/`preview?` declaration on the class, with the list built from `Assistant::Function.descendants` or a registry file per area). Pairs with BC8. |
| F-H5 | `app/controllers/settings/hostings_controller.rb` | 519 | 21 | 12 | Every provider and AI setting goes through one `update` action (lines 65–314, about 250 lines). | See F-M2. |
| F-H6 | `app/models/family/auto_transfer_matchable.rb` | 381 | 9 | 13 | Transfer matching (W2) is a current focus. Many open PRs tune the same SQL. | No split. Coordinate instead (O-B8 CODEOWNERS), because the file is one algorithm. |
| F-H7 | `app/models/setting.rb` | 343 | 16 | 7 | 45 `field` declarations across AI (`openai_*` 5, `llm_*` 4, `external_*` 4, `jev_*` 3, `anthropic_*` 3, `ai_*` 2) and non-AI areas. | S6 / BC5: AI keys move to `AiConfig`. |
| F-H8 | `app/controllers/mcp_controller.rb` | 244 | 8 | 8 | Protocol handling, auth and tool dispatch in one controller (W15). | `Mcp::Server` (JSON-RPC dispatch), `Mcp::Auth` (Doorkeeper and env token), and a thin controller. Pairs with [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)* and BC8. |
| F-H9 | `config/schedule.yml` | 105 | 10 | 6 | Shared cron list. | Leave it. It's small, and conflicts are one-line. |
| F-H10 | `db/schema.rb` | — | 118 | 73 | Generated by migrations. | Can't be split. Ask for one migration per PR, and rebase just before merge. |

## 2. Files crossing MVC boundaries (F-M)

| ID | File | What crosses | Split |
|---|---|---|---|
| F-M1 | `app/views/settings/hostings/*` | **70 `ENV` reads in views.** The AI partials alone have `_openai_settings` 11, `_assistant_settings` 9, `_provider_selection` 7, `_anthropic_settings` 6, `_jev_settings` 4 and `_categorization_provider_selector` 4. The view decides precedence and "locked" state, which is where the web/worker drift in 01 D3 comes from. | A settings presenter per section that reports `value`, `source` (env, setting or default) and `locked?`, generated by `AiConfig` (S6). Views only render. |
| F-M2 | `app/controllers/settings/hostings_controller.rb` | Domain logic in the controller: parsing and validating categorization tuning (`unit_interval!`), fetching external-assistant models over HTTP (`external_assistant_model_ids`), updating encrypted settings, and resyncing the auto-sync scheduler. | One form object per section (`Settings::AiForm`, `Settings::AssistantForm`, …) and one controller per section, so each provider PR touches its own pair of files. |
| F-M3 | `app/controllers/family_merchants_controller.rb` | Provider availability (`Provider::Registry.get_provider(:openai)`, D4 #1), a job lock in `Rails.cache` for `enhance`, and merchant-merge logic (`perform_merge`). | Merge moves to `Merchant::Merger`. The enhance lock moves into `EnhanceProviderMerchantsJob` (or `AiJob`, S5). Availability goes through `Ai::Router.available?` (S1). |
| F-M4 | `app/helpers/bills_helper.rb#bills_one_shot_ai_available?`, `app/helpers/insights_helper.rb#insight_dig_in_available?` | Helpers call `Provider::Registry.preferred_llm_provider` to decide whether AI features show. | `Ai::Router.available?(task, user:)`. Helpers only format. |
| F-M5 | `app/jobs/generate_insights_job.rb` (206 lines) | The job holds the feed's domain logic (`upsert_insights`, `expire_stale_insights`, dedup by key) and also renders three partials for broadcast. | `Insight::Feed` model for the upsert, expire and dedup logic. `Insight::FeedBroadcaster` for the three Turbo targets (register I24). The job just calls them. |
| F-M6 | `app/models/chat.rb` (307 lines) | Builds DOM ids and broadcasts partials, which is normal Turbo Rails. It also chooses provider models (`default_model`), classifies provider errors for display, and runs the undelivered-response watchdog. | Keep the broadcasts. Move model choice to the router (S1/BC3), and error classification to `Chat::ErrorPresenter`. |
| F-M7 | `app/views/chats/_worker_health_warning.html.erb` | The view queries `BackgroundJobHealth.healthy?` directly. | Minor. Pass it in from the controller or a helper. |

Acceptable as they are: `settings/classifiers/*` views reading `Family::BayesSettings::RANGES`/`CHOICES`/`STEPS` (constants used as form metadata), `BayesEvaluationJob` broadcasting one panel, and `Assistant::Function::CreateGoal` building a URL for the model's answer.

## 3. Files not constrained to one resource (F-R)

| ID | File | Lines | Resources | Mixed concerns | Split |
|---|---|---|---|---|---|
| F-R1 | `app/models/family.rb` | 938 | 29 | Tenancy root, bank connections, sync, AI/ML facade, classifier rules, prompts | As F-H2 |
| F-R2 | `app/models/pdf_import.rb` | 596 | 10 | Import record, statement-vault creation, the AI processing (`process_with_ai`, `extract_transactions`), row generation, vector upload, the next-steps email | `PdfImport::AiProcessor` (W11 stages), `PdfImport::RowBuilder`. The model keeps state and status. |
| F-R3 | `app/models/chat.rb` | 307 | 10 | Chat record, assistant routing, job health, model choice, error classification | As F-M6 |
| F-R4 | `app/controllers/settings/hostings_controller.rb` | 519 | 9 | Every provider, assistant, categorization, sync schedule | As F-M2 |
| F-R5 | `app/controllers/imports_controller.rb` | 345 | 8 | CSV, Sure and PDF imports, plus the synchronous non-PDF document upload into the vector store (W12) | `DocumentsController` for vector documents (and the BC6 job). Imports keep imports. |
| F-R6 | `app/models/provider/openai.rb` | 939 | 7 | Chat transport (native and generic), batch operations, budgets, usage, Langfuse | Chat transport out (lines ~404–698), then BC3 |
| F-R7 | `app/models/family/auto_merchant_detector.rb` | 165 | 6 | Calls the provider, then a four-step merchant lookup across `FamilyMerchant` and `ProviderMerchant` | `Merchant::Resolver` for the lookup, shared with W10's dedupe |
| F-R8 | `app/controllers/family_merchants_controller.rb` | 198 | 6 | CRUD, merge, AI enhance | As F-M3 |
| F-R9 | `app/helpers/bills_helper.rb` | 493 | 5 | Bills formatting and paycheck-plan formatting (`paycheck_*`, about 10 methods) | `PaycheckPlanHelper` |
| F-R10 | `app/controllers/rules_controller.rb` | 239 | 5 | Rules CRUD plus AI cost estimates (`LlmUsage`) and the AI cache reset action (W21) | AI cache reset to its own controller (or gone with BC1) |

## 4. When to split

- **a. Prior to the refactor:** a pure move of code that refactor PRs will edit. Splitting first means each refactor PR touches one small file, and refactor PRs don't collide with each other or with feature PRs.
- **b. As part of the refactor:** the split's target shape is a new refactor interface (router, `AiConfig`, `AiJob`, a gateway task, the resolver, the MCP server). Splitting earlier would mean doing the work twice.
- **c. It doesn't matter when:** the refactor doesn't touch the file, or barely does. Split whenever collisions make it worthwhile.

The "Serves" column names the item each split helps: S* from 02, BC* from 05.

| File | IDs | Split? | When | Why that timing | Serves |
|---|---|---|---|---|---|
| `app/models/family.rb`: AI/ML facade (`family.rb:174–592`) | F-H2, F-R1 | Yes | **a** | Every refactor PR edits these methods. Extracting them first moves that work out of a file 20 open PRs already touch. | S10, BC1–BC3, BC11 |
| `app/models/family.rb`: 24 `*Connectable` includes | F-H2, F-R1 | Yes | **c** | Bank-connection work, not AI. It only reduces collisions. | — |
| `config/locales/views/settings/en.yml` | F-H3 | Yes | **a** | BC5, BC8 and BC9 rewrite the `llm_usages`, `mcp` and `ai_prompts` strings in this shared file. | S6, BC5, BC8, BC9 |
| `app/models/assistant.rb` (tool list) | F-H4 | Yes | **a** | BC8 adds `surfaces` and `read_only?` to every tool. Self-registration first makes that one mechanical PR instead of edits to a list that 14 open PRs change. | BC8, O-B7 |
| `app/controllers/settings/hostings_controller.rb` | F-H5, F-M2, F-R4 | Yes | **a** | One controller and form per section first. S6/BC5 then changes one section per PR. | S6, BC5 |
| `app/models/provider/openai.rb` (chat transport) | F-R6 | Yes | **a** | Pure move of lines ~404–698. BC3 tasks and BC4 history then edit separate files. | S2, BC3, BC4 |
| `app/models/pdf_import.rb` (AI processing) | F-R2 | Yes | **a** | Moving `process_with_ai` and extraction out first lets the BC3 `extract_pdf` task and BC6 replace one small class. | S2, S8, BC3, BC6 |
| `app/views/settings/hostings/*` (`ENV` reads) | F-M1 | Yes | **b** | The presenter's `value`, `source` and `locked?` come from `AiConfig`. Before that, it would copy today's precedence code. | S6, BC5 |
| `app/models/setting.rb` | F-H7 | Yes | **b** | The AI fields move into `AiConfig`. There is nothing to split them into before it exists. | S6, BC5 |
| `app/helpers/bills_helper.rb#bills_one_shot_ai_available?`, `app/helpers/insights_helper.rb#insight_dig_in_available?` | F-M4 | Yes | **b** | Replaced by `Ai::Router.available?`. | S1, BC3, BC10 |
| `app/models/chat.rb` | F-M6, F-R3 | Yes | **b** | Model choice moves to the router. The error presenter could go any time, but it touches the same lines. | S1, BC3, BC4 |
| `app/controllers/family_merchants_controller.rb` | F-M3, F-R8 | Yes | **b** (merge: **c**) | Availability goes to the router and the enhance lock to `AiJob`. `perform_merge` → `Merchant::Merger` is independent. | S1, S5, BC3, BC7 |
| `app/controllers/mcp_controller.rb` | F-H8 | Yes | **b** | Split into `Mcp::Server` and `Mcp::Auth` alongside the scope, annotation and audit changes ([#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)*), not before them. | BC8, A13 |
| `app/controllers/imports_controller.rb` (vector documents) | F-R5 | Yes | **b** | Moves with the non-PDF upload going to a job. | S8, BC6 |
| `app/models/family/auto_merchant_detector.rb` | F-R7 | Yes | **b** | The merchant lookup becomes `Merchant::Resolver` when detection becomes an enrichment stage. | BC1, BC2 |
| `app/controllers/rules_controller.rb` (AI cache reset, cost estimate) | F-R10 | Yes | **b** | BC1 removes the AI cache. Under the non-breaking path (02 §5) it is **c**. | BC1, BC9 |
| `config/routes.rb` | F-H1 | Yes | **c** | 44 open PRs, but app-wide. The refactor changes only about 12 AI route lines. It needs agreement beyond the AI area. | — |
| `app/jobs/generate_insights_job.rb` | F-M5 | Yes | **c** | Insights (W17) are deterministic Ruby, outside the LLM refactor. | — |
| `app/helpers/bills_helper.rb` (paycheck plan) | F-R9 | Yes | **c** | Not AI. | — |
| `app/views/chats/_worker_health_warning.html.erb` | F-M7 | Minor | **c** | One query in a view. | — |
| `app/models/family/auto_transfer_matchable.rb` | F-H6 | No | — | One algorithm. Coordinate the 13 open PRs (O-B8) instead. | — |
| `config/schedule.yml` | F-H9 | No | — | 105 lines, one-line conflicts. | — |
| `db/schema.rb` | F-H10 | No | — | Generated. One migration per PR, and rebase before merge. | — |
| `app/models/rule.rb` | — | No | — | 3 open PRs. BC2 rewrites its AI branches anyway. | BC2 |
| `app/models/family/bayes_*.rb`, `app/models/assistant/function/*.rb` | — | No | — | Low churn, or already one concern per file. | — |

**Counts:** a = 6, b = 9, c = 5, no split = 5. `family.rb` and `family_merchants_controller.rb` appear under two timings because different parts of each split at different times.

## 5. Order

Within each group, splits go in order of open-PR overlap, because that is where conflicts happen today, then by how much refactor work they unblock. Steps in group a are pure moves.

**a. Before the refactor**
1. **F-H2 / F-R1:** the `family.rb` AI/ML facade into `Family::Classification` (S10). 20 open PRs.
2. **F-H3:** one settings locale file per page. 16 open PRs.
3. **F-H4:** tool self-registration. The list stays identical, with a test that compares old and new. 14 open PRs.
4. **F-H5 / F-M2:** one hostings controller and form per section. 12 open PRs.
5. **F-R6:** chat transport out of `provider/openai.rb`.
6. **F-R2:** AI processing out of `pdf_import.rb`.

**b. With the refactor:** each split lands in the same PR series as the item it serves.
- With S1 / BC3 (router): F-M4 availability helpers, `chat.rb` model choice (F-M6), and `family_merchants_controller` availability (F-M3).
- With S5 (`AiJob`): the enhance lock (F-M3).
- With S6 / BC5 (`AiConfig`): the hostings presenters (F-M1) and `setting.rb` (F-H7).
- With S8 / BC6: vector documents out of `imports_controller.rb` (F-R5).
- With BC8 and [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)*: the `mcp_controller.rb` split (F-H8).
- With BC1 / BC2: `Merchant::Resolver` (F-R7) and the `rules_controller.rb` AI cache action (F-R10).

**c. Any time**
- **F-H1:** `routes.rb` → `draw` files. It has the most open PRs (44), but it's an app-wide decision.
- **F-M5:** the insights feed out of `GenerateInsightsJob`.
- **F-R9:** a paycheck-plan helper.
- **F-H2 (connectable part):** grouping the `*Connectable` includes.
- **F-M3 (merge part):** `Merchant::Merger`.
- **F-M7:** the worker-health view query.

**Not split:** `db/schema.rb`, `config/schedule.yml`, `family/auto_transfer_matchable.rb`, `rule.rb`, the Bayes files and `assistant/function/*` (see §4).
