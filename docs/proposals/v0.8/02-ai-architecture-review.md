# Sure: architecture and workflow review of the AI / ML pipeline

**Role:** open-source project architect
**Input:** [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md) (the workflow map traced on `origin/main` @ `56105a3b5`), plus repository metrics taken on 2026-10-23
**Scope:** the project, its workflows and its architecture. This is not a line-level code review.
**Two lenses:** (A) a traditional Rails + Sidekiq application, and (B) a fast-moving open-source project whose contributions mostly come from LLM coding agents

---

## 0. Executive summary

Sure's AI layer **works and is unusually well commented**, but it grew **operation by operation and provider by provider**. Each new capability (categorize, detect merchants, enhance, PDF, bills, chat, Jev, Bayes) brought its own provider choice, batching, output parsing, failure policy and settings precedence. In a normal project that is technical debt. In a project where **most changes are written by agents that copy the nearest example**, every duplicated pattern becomes a template that gets copied again. Debt compounds faster, and so does the payoff of consolidating.

The five changes with the most leverage:

| # | Recommendation | Why it matters to both lenses |
|---|---|---|
| 1 | **One AI router** (*task → provider + model + transport*) replacing the three resolution paths and the scattered "is AI available?" checks | It removes a whole class of drift bugs (e.g. the Enhance button checks only OpenAI). Per-task models ([#4245](https://github.com/we-promise/sure/issues/4245)) follow almost for free. Agents get one obvious call site. |
| 2 | **One structured-output primitive per transport**, with each operation reduced to *prompt + schema + mapper* | It collapses 12 provider worker classes and 13 duplicated helper definitions. A new AI feature becomes a small declarative file that agents can copy safely. |
| 3 | **Make the rule pipeline's ordering semantics honest** (phases or continuations) | AI results currently land after the runner has finished, so "top rule wins" quietly does not apply to AI. This is the main architectural inconsistency [#4310](https://github.com/we-promise/sure/issues/4310) left behind. |
| 4 | **Turn invariants into executable checks** (architecture tests and custom cops), not prose | At 376 commits from 69 authors in 30 days, reviewers cannot hold the invariants in their heads. Agents reliably fix failing checks. They do not reliably read docs. |
| 5 | **Commit a maintained, partly generated AI-pipeline guide** to `docs/llm-guides/` | The current guides do not mention JSON modes, the batch slicer or the enrichment/lock contract at all. Every contributor's agent re-derives them from code, differently each time. |

---

## 1. Evidence base

| Signal | Value | What it implies |
|---|---|---|
| Commits on `main`, last 30 days | **376** | Very high change rate. Architecture decisions are made inside PRs. |
| Distinct authors, last 30 days | **69** | Few contributors hold the whole picture. |
| `Co-Authored-By: Claude` trailers, last 30 days | **529** (several per commit) | The agent is the main author. Its habits shape the codebase. |
| Open PRs | **≥200** | Review capacity is the bottleneck, not authoring capacity. |
| Commits touching core AI files, last 30 days | **41** | The AI layer is a hot spot. |
| Guides mentioning `json_mode` / `BatchSlicer` / `Enrichable` | **0 / 0 / 0** | The key contracts are documented only in code comments. |
| Guides mentioning `capsule`, `LlmConcept`, `preferred_llm_provider` | **1 each** (hosting or classification-provider docs) | No architecture-level AI guide exists. |
| `parse_json_flexibly` definitions | **5** | Copy-the-neighbour duplication. |
| `strip_thinking_tags` definitions | **4** | Same. |
| `extract_http_status_code` definitions | **4** | Same. |
| Comment "Honors Setting.llm_provider (issue [#2113](https://github.com/we-promise/sure/issues/2113))" | **6** copies | Agent fingerprint: a fix pattern repeated per call site instead of centralized. |
| Agent instruction surfaces | `AGENTS.md`, `CLAUDE.md`, 7 × `.cursor/rules`, `.junie`, `.gemini`, `copilot-instructions`, 16 `docs/llm-guides/*` guides (plus their `README.md`) | Good investment. There is already a drift problem (hence `instruction-preservation-map.md`). |

The map itself is evidence. Producing it took dozens of file reads across about 60 files. **Every agent working on an AI feature pays that cost again, partially and inconsistently.**

---

## 2. Lens A: Rails + Sidekiq application architecture

### 2.1 Challenges

**A1. Three provider-resolution paths and many availability checks.**

> **Related PRs:** [#4244](https://github.com/we-promise/sure/issues/4244) chat routing fix · [#4249](https://github.com/we-promise/sure/issues/4249) env-first provider · [#3979](https://github.com/we-promise/sure/issues/3979) Gemini 3 · [#4291](https://github.com/we-promise/sure/issues/4291) Gemini 4 · [#3694](https://github.com/we-promise/sure/issues/3694) *(open, v0.7.7)* another model-discovery path

`preferred_llm_provider` (batch, PDF, bills), `resolved_categorization_provider` (Jev or LLM) and `get_model_provider(ai_model)` (chat), plus `Chat.default_model`, the vector-store default, `User#ai_available?`, `insight_dig_in_available?`, `bills_one_shot_ai_available?`, `TransactionResource#offered?` and the Enhance button's `get_provider(:openai)`. Each encodes "which AI applies here?" slightly differently. The Enhance-button bug is the predictable result, and more will follow every time a provider is added (Gemini support already landed on the side, in commit `3a391a35a`).

**A2. A provider × operation × transport matrix, implemented by hand.**

> **Related PRs:** [#4261](https://github.com/we-promise/sure/issues/4261) one cell missed json_mode · [#4178](https://github.com/we-promise/sure/issues/4178) one transport's tool_choice quirk · [#3605](https://github.com/we-promise/sure/issues/3605) *(open, v0.7.7)* adds reasoning effort to one transport

There are 3 transports (OpenAI native, OpenAI-compatible, Anthropic) plus Jev, and 7 operations (categorize, detect, enhance, PDF classify, statement extract, bill suggest, chat). The structured-output concerns (schema, JSON mode, fallback, think-tag stripping, fuzzy key aliases, usage recording, Langfuse spans) are re-implemented in each worker class. Bug fixes land per cell. `[#4261](https://github.com/we-promise/sure/issues/4261)` ("honor json_mode in the PDF extraction path") is literally a fix for one cell that missed a cross-cutting concern.

**A3. Batching happens in three uncoordinated places.**
The rule action batches by `LLM_MAX_ITEMS_PER_CALL`. OpenAI re-slices by token budget. Anthropic does not slice. Jev fans out per transaction with its own thread pool inside a Sidekiq thread. Nobody owns "how big is one unit of AI work", so cost, latency and context overflows are emergent properties.

**A4. The rule pipeline promises an ordering it does not deliver for AI.**

> **Related PRs:** [#4013](https://github.com/we-promise/sure/issues/4013) · [#4310](https://github.com/we-promise/sure/issues/4310)

`Rule::Runner` gives deterministic top-rule-wins semantics with claims and `stop_processing`. AI actions return "async, pending N" and finish later through a row-locked counter on `RuleRun`. Consequences:
- Rules below an AI rule never see the AI's result in the same run.
- AI actions declare `reserves_claimed_attributes? = false` as a workaround, so they neither claim nor block.
- The Classifier page "Run" button (`BayesCategorizeJob`) is a second entry point that ignores rule order, conditions and (for Bayes) the active flag.

[#4310](https://github.com/we-promise/sure/issues/4310) made Bayes and the matcher rules, which is the right direction. AI is now the odd one out.

**A5. Failure semantics differ for the same kind of work.**

| Workflow | On provider failure |
|---|---|
| W8 categorize | raise, so `RuleRun` fails and Sidekiq retries (with the default backoff) |
| W9 detect merchants | log and return 0, so `RuleRun` shows **success** |
| W10 enhance | skip the batch silently |
| W11 PDF | `discard_on Provider::Error` (no retry), import marked failed |
| W20 bills | friendly error in the HTTP response |
| W13 chat | `chat.add_error` with a Retry button |

Each choice is defensible on its own. Together they make it hard to operate (to answer "did AI run last night?") and impossible for an agent to infer the correct policy for a new feature.

**A6. Configuration precedence is reimplemented per key.**

> **Related PRs:** [#4019](https://github.com/we-promise/sure/issues/4019) another timeout setting · [#4249](https://github.com/we-promise/sure/issues/4249) precedence fix for one key · [#3605](https://github.com/we-promise/sure/issues/3605) *(open, v0.7.7)* OPENAI_REASONING_EFFORT

About 50 AI-related env vars (plus about 20 instance settings) each hand-roll "ENV > Setting > default", with variations: some are ENV-only, some are family columns with ENV overrides, some clamp, some treat 0 as unset. Side effects are attached ad hoc: changing `openai_model` through the Settings UI clears the AI cache for **every family**, but changing it through ENV, or changing the Anthropic model, does not. `hostings_controller` permits all of them on **one giant line**, which is a merge-conflict magnet.

**A7. The enrichment and lock model is the real cross-cutting contract, and it is undocumented.**
Every writer (provider sync, rules, matcher, Bayes, AI, user) goes through `enrich_attribute`, and the *lock policy differs per writer* (AI always locks; Bayes and the matcher lock optionally and record `locked_by_*` flags; users lock). That policy decides whether the next stage can correct a mistake. It deserves to be a first-class concept, but today it is spread across five classes.

**A8. Sidekiq topology has become product behaviour.**

> **Related PRs:** [#4237](https://github.com/we-promise/sure/issues/4237) AI capsule · [#4262](https://github.com/we-promise/sure/issues/4262) dev Sidekiq · [#4310](https://github.com/we-promise/sure/issues/4310) Bayes off the AI lane · [#4239](https://github.com/we-promise/sure/issues/4239) insights off the AI lane

- The `ai` capsule defaults to **one thread**, strict-ordered with chat first, and **every background LLM call shares it**: chat, categorization, merchant detection, merchant enhancement and PDF import ([01 D3](01-ai-ml-workflow-map.md#d3-process-placement-web-vs-worker)). That protects syncs, but one long PDF or a 40-job categorization run still blocks chat *while running*. Strict ordering only helps between jobs.
- Keeping non-LLM work off that thread already pays off, and recent PRs show the pattern. [#4310](https://github.com/we-promise/sure/issues/4310) took Bayes out of `AutoCategorizeJob` (where it ran on the ai lane before the LLM) and made it a rule on the default capsule. [#4239](https://github.com/we-promise/sure/issues/4239) replaced LLM-written insight text with deterministic text and moved `GenerateInsightsJob` from `ai_low_priority` to `scheduled`. Both freed the AI lane for work that needs a model. The lane test in O-B1 would keep it that way.
- Rule jobs on `medium_priority` run Bayes and the matcher **inline**, which is CPU-bound in-memory work of up to 5k transactions per family per sync.
- `find_best` evaluation can run for minutes on `low_priority`.
- There are no per-job timeouts. Per-family serialization uses three different mechanisms: advisory locks (rules, insights, recurring), cache flags (enhance, evaluation) and `sidekiq_options lock:` (cron jobs).

**A9. LLM calls inside web requests.**
Four paths call a model from a Puma thread ([01 D3](01-ai-ml-workflow-map.md#llm-calls-on-web-threads)): bill smart-fill and smart-configure, the non-PDF document upload (embeddings), MCP `tools/call` running `import_bank_statement` (a whole-PDF extraction), and the AI health probes. With local models each one holds a Puma thread for minutes, outside the ai lane's queueing and invisible to Sidekiq metrics. These are the places where the "AI happens in the ai lane" principle is broken, and nothing stops a new feature from adding a fifth.

**A10. Observability is spread across four channels with no correlation.**
Langfuse traces, `llm_usages`, `DebugLogEntry` and AI-health snapshots each tell part of the story. No ID flows sync → rule run → AI job → provider call, so "why does this transaction have this category?" has no single answer.

**A11. Governance gap.**

> **Related PRs:** [#4192](https://github.com/we-promise/sure/issues/4192) share permissions in bulk categorize · [#4004](https://github.com/we-promise/sure/issues/4004) guests can't mutate family config · [#3709](https://github.com/we-promise/sure/issues/3709) *(open, v0.7.7)* per-person ownership

Chat and bill AI respect `User#ai_enabled?`. Rule-driven AI only needs a configured provider, so one admin's rule sends every member's transaction text to a third party. Whether or not that is intended, it should be a stated policy, not an accident of which entry point checks what.

**A12. Two processes, one configuration story.**
Web and worker each resolve ENV > Setting > default for themselves, and some settings are read by only one of them: `AI_RESPONSE_TIMEOUT` only by the web (the chat watchdog), `ASSISTANT_MAX_TOOL_CALL_ITERATIONS` only by the worker, `RAILS_AI_MAX_THREADS` by both for different purposes ([01 D3](01-ai-ml-workflow-map.md#which-process-reads-which-setting)). Compose hides this by sharing one env file. Helm, quadlet and bare-metal installs set env per process, and a drift shows up as "the settings page says X but the jobs do Y". The on-demand worker AI health check (W22) exists because the processes can differ. It shows the worker's provider, model, endpoints, request timeout and embedding settings beside the web's, but not batch size, context window, JSON mode, tool rounds or the chat watchdog.

**A13. MCP is a second front door to the tool registry, with weaker guards than chat.**

> **Related PRs:** [#3990](https://github.com/we-promise/sure/issues/3990) rule tools with preview · [#4147](https://github.com/we-promise/sure/issues/4147) mcp_only · [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)* MCP-only `mcp` scope · [#3025](https://github.com/we-promise/sure/issues/3025) *(open, v0.7.7)* MCP-only destructive tools

`/mcp` serves `Assistant.function_classes(user)` directly ([01 W15](01-ai-ml-workflow-map.md#the-interface-sure-exposes)). That keeps chat and MCP at parity, but it also means every function added to the registry is callable by external agents straight away, and MCP has fewer of the guards chat has:
- **All or nothing.** The only accepted OAuth scope is `read_write`, which also grants JSON API writes. [#4283](https://github.com/we-promise/sure/issues/4283) separates *where* a token works (a new `mcp` scope that the JSON API rejects) but not *what* it can do: `mcp` still covers all 30 tools. A read-only MCP grant would need its own scope (for example `mcp:read`). Reusing the JSON API's `read` scope would undo #4283's separation.
- **No write signal.** No tool sends `readOnlyHint` or `destructiveHint`, so MCP clients that ask the human before destructive calls can't tell which of the 30 tools write.
- **No way back to the human.** With `POST`-only JSON responses the server can't use elicitation to ask for a confirmation. The [#3990](https://github.com/we-promise/sure/issues/3990) preview token is something the model fills in for itself.
- **No trail.** Tool calls go only to the log. No audit row or trace records which agent changed what.
- **Different gating.** MCP doesn't check `ai_enabled`, `assistant_type` or a configured provider. That is reasonable, since the client brings its own model, but it isn't written down anywhere.

### 2.2 Opportunities

- **O-A1. Name the cascade as the product.** Matcher → Bayes → (Jev | LLM), from free to cheap to paid, ordered by rules, with confidence and provenance recorded. The pieces exist (rule order, `enrich_attribute` metadata, shadow comparisons, `BayesEvaluation`, evals). Promoting "the classification cascade" to an explicit concept with one diagram, one settings page and one report gives users a cost/quality dial and gives contributors a frame for where a new stage belongs.
- **O-A2. Per-task models ([#4245](https://github.com/we-promise/sure/issues/4245)) as a by-product of the router.** For example: chat on Claude, background categorization on a local qwen, PDF on a vision model.
- **O-A3. Provenance UI.** `DataEnrichment` already records source, confidence, model and settings digest. A "why this category?" popover is mostly a view.
- **O-A4. A correlation ID end to end.** Pass `sync_id` / `rule_run_id` into the Langfuse trace metadata and into `llm_usages.metadata`. That makes cost per sync and failure per run queryable.
- **O-A5. Use the eval framework for change control.** `evals:ci_regression` and recorded datasets exist. Wire them to prompt and schema changes (see §3.2).

### 2.3 Simplifications (Rails lens)

| ID | Simplification | Replaces | Effort | Risk |
|---|---|---|---|---|
| **S1** | `Ai::Router.for(task, family:)` returns `{provider, model, transport}` or nil with a reason. One `available?(task, user:)`. | 3 resolution paths, `Chat.default_model`, about 8 availability checks, the vector default | M | Low: pure refactor behind existing call sites |
| **S2** | `Ai::StructuredCall` per transport: `(instructions, schema, input) → Hash`. It owns JSON mode and fallback, think-tag stripping, tool-forcing, retries, usage and tracing. Operations become `Ai::Operations::Categorize = {prompt_key, schema, build_input, map_output}`. | 12 worker classes, 5 + 4 + 4 duplicated helper definitions | L | Medium: needs cross-transport contract tests first (see §3.2) |
| **S3** | A single batching policy: the operation declares a unit (per item or per batch) and a budget; the router or transport decides slicing. | 3 batching layers | M | Low |
| **S4** | Rule runner phases: run deterministic and Ruby-ML rules, then await AI jobs (a continuation when `pending_jobs_count` reaches 0), then **re-run rules below the AI rule** for the affected IDs only. *Alternative:* when a run contains AI actions, run the whole runner on the `ai` capsule and call AI synchronously. That is simpler and keeps ordering, at the cost of AI-lane occupancy. | the `async: true` special case, the `reserves_claimed_attributes? = false` workaround, `BayesCategorizeJob` as a parallel path | M | Medium: product-visible timing change |
| **S5** | `AiJob` base class: queue lane, failure policy (an explicit `retry`/`discard`/`record` declaration), RuleRun callbacks, per-family concurrency key, trace context. | 5 AI jobs with copied rescue/callback code | S | Low |
| **S6** | A config registry: `AiConfig.key :llm_max_items_per_call, env:, setting:, default: 25, clamp:, scope: :instance, on_change: …`. Generates the settings form permit list, the docs table and the AI-health display. | about 40 hand-rolled precedence methods, the one-line permit list, inconsistent cache-clear side effects | M | Low |
| **S7** | A `Enrichment::Policy` per source (`locks?`, `overrides?`, `trainable?`), referenced by every writer. | lock logic in 5 classes, `locked_by_*` flags | S | Low |
| **S8** | Move bill smart-fill, the non-PDF document upload and MCP `import_bank_statement` to jobs on the ai lane, with a Turbo stream (UI) or a pending import (MCP) as the response. Keep the health probes as the one allow-listed exception. | the synchronous LLM and embedding calls in user flows (A9) | S–M | Low |
| **S9** | Delete the Classifier "Run" special path: make it "Apply" on the two classifier rules (`RuleJob`). | `BayesCategorizeJob` semantics that differ from the nightly run | S | Low |
| **S10** | Split `Family` AI/ML concerns out of `family.rb` (classifier rules, categorization provider, AI prompts already split) into `Family::Classification`. | a merge hotspot that every AI PR touches | S | Low |

---

## 3. Lens B: fast, agent-driven open-source contribution

### 3.1 Challenges

**B1. Agents copy the nearest neighbour, so duplication is self-reinforcing.**
An agent asked to "add Anthropic support for X" finds `Provider::Openai::X`, mirrors it, and copies the helpers. An agent asked to fix a bug in one cell fixes that cell. The six identical "Honors Setting.llm_provider (issue [#2113](https://github.com/we-promise/sure/issues/2113))" comments show this exactly: a cross-cutting rule applied six times instead of once. **In this project the codebase's examples are its strongest form of guidance.** Bad examples get multiplied.

**B2. Context cost, and partial context.**
To change anything in the AI pipeline correctly, an agent needs a picture like the workflow map: three resolution paths, lane topology, lock policy, rule semantics. That picture is not in the repo, so each agent builds a partial one within its budget and optimizes locally. The result is correct-looking PRs that break a contract they never saw (e.g. a new AI writer that does not lock, or a new job on the wrong queue).

**B3. Feature matrices get filled in unevenly.**

> **Related PRs:** [#3025](https://github.com/we-promise/sure/issues/3025) *(open, v0.7.7)* MCP-only destructive tools diverge from the chat registry · [#3990](https://github.com/we-promise/sure/issues/3990) rule tools

Features land for one provider and are back-filled later ([#1984](https://github.com/we-promise/sure/issues/1984) and [#1985](https://github.com/we-promise/sure/issues/1985) added Anthropic after the fact). The UI gates (A1) lag behind. Each half-filled cell is a support issue for self-hosters, whose setups are the most varied: Ollama, LM Studio, vLLM, proxies.

**B4. Architecture decisions happen implicitly, inside large PRs.**

> **Related PRs:** [#4310](https://github.com/we-promise/sure/issues/4310) · [#4013](https://github.com/we-promise/sure/issues/4013) · [#4237](https://github.com/we-promise/sure/issues/4237) · [#4239](https://github.com/we-promise/sure/issues/4239)

[#4310](https://github.com/we-promise/sure/issues/4310) turned Bayes and the matcher into rules, added a data migration with activation heuristics, and removed settings. [#4013](https://github.com/we-promise/sure/issues/4013) introduced ordered rules. [#4237](https://github.com/we-promise/sure/issues/4237) introduced the AI capsule. Each was a sound decision, but each is recorded only in the PR thread and in code comments. The next agent cannot find *why*, so it may undo it or work around it.

**B5. Comments are used as a changelog.**
The code is heavily commented with narrative and issue history ("the symptom we chased in the [#1984](https://github.com/we-promise/sure/issues/1984) review"). Agents add these generously, and they go stale as fast as the code changes (the BayesRunner comment still describes the pre-[#4310](https://github.com/we-promise/sure/issues/4310) cascade). Stale comments are worse for agents than none: agents trust them.

**B6. Review capacity is the scarce resource.**
With ≥200 open PRs and 69 active authors, maintainers cannot enforce unwritten invariants by review. The invariants that matter here (lane choice, lock policy, provider parity, usage attribution, consent) are exactly the ones that don't show up in a diff.

**B7. Prompt and schema changes are behaviour changes with no behavioural gate.**
A prompt edit can shift categorization accuracy for every self-hoster, but CI checks only that the code runs. `/settings/ai_prompts` overrides add another variable: the tests cover the default prompts, not the variants users actually run.

**B8. Too many places to write instructions.**

> **Related PRs:** [#1559](https://github.com/we-promise/sure/issues/1559) *(open, v0.7.7)* in-repo OpenClaw bootstrap skill · [#3677](https://github.com/we-promise/sure/issues/3677) *(open, v0.7.7)* mise dev services

`.cursor` (7), `.junie`, `.gemini`, `copilot`, `CLAUDE.md` → `AGENTS.md`, and 16 guides. The existence of `instruction-preservation-map.md` shows the maintainers already feel the drift. Adding AI-pipeline guidance in N places would make it worse.

**B9. Hot files cause conflicts.**
`family.rb`, `setting.rb`, `hostings_controller.rb` (the one-line permit), `config/sidekiq.yml`, `config/locales/*` and `Rule::Registry::TransactionResource` are touched by many parallel agent PRs. Long-lived agent branches rebase repeatedly, and auto-resolved conflicts are where subtle regressions enter.

### 3.2 Opportunities

- **O-B1. Executable architecture (highest leverage).** Encode invariants as tests and cops that fail with a *prescriptive message* (agents act on these reliably). Write the cops as custom RuboCop cops in `lib/rubocop/cop/`. RuboCop already runs in CI through `rubocop-rails-omakase`, so no new tool is needed.
  - Every class including `LlmConcept` implements every operation or declares `unsupported :op` (a parity matrix test, which fixes B3).
  - Every job that calls `Provider::Registry`/`Ai::Router` is on an `ai_*` queue, and nothing else is (a lane test, for A8).
  - No controller action reaches an LLM or embedding call, except an explicit allow-list (the health probes). A test that stubs the provider to raise when called outside a job would catch it (for A9).
  - Every AI setting declares which process reads it (web, worker or both), so the generated env table (O-B4) and the effective-configuration view can flag a value that only one process has (for A12).
  - Every call to an `enrich_attribute` writer passes a `source` that has a registered `Enrichment::Policy` (for A7).
  - No `Provider::Registry.get_provider(:openai|:anthropic)` outside the router (a cop, for A1).
  - Every provider operation receives `family:` (usage attribution).
  - Every `Assistant::Function` declares whether it writes data, and MCP `tools/list` maps that to `readOnlyHint` / `destructiveHint` (for A13).
  - An ENV read for an AI key goes through the config registry (a cop, for A6).
- **O-B2. Cross-transport contract tests with recorded fixtures.** Use one shared test suite per operation, run against OpenAI native, OpenAI-compatible (with JSON modes none, json_object and strict), and Anthropic. Fixtures should include "bad" model output (think tags, wrong keys, prose around JSON). This is the safety net that makes S2 possible, and it turns "works with my Ollama" PRs into checkable claims.
- **O-B3. A prompt-change eval gate.** When a PR touches `instructions`, a schema or `ai_prompt` defaults, CI runs `evals:ci_regression` on a small committed dataset using recorded responses (free), and comments the metric delta. A live-model run stays a maintainer-triggered label. This gives agents a number to optimize instead of a vibe.
- **O-B4. Generated reference docs.** Generate the env/settings table (from S6), the job/queue table (from `queue_as` plus `sidekiq.yml`), the rule-action table (from the registry) and the provider capability matrix (from O-B1) in CI, failing when stale. Hand-written docs then cover only *why* and *how to extend*, which change slowly.
- **O-B5. One AI-pipeline guide with "extension recipes".** Add `docs/llm-guides/ai-pipeline.md`, linked from `AGENTS.md`'s "Provider and feature work" section only (avoiding B8). It should contain the one-page cascade diagram, the invariants list (which mirrors O-B1, so prose and tests agree), and recipes: *add an AI operation*, *add a provider*, *add a classifier stage*, *add an AI-triggering assistant tool*. Recipes beat descriptions for agents: they are the "nearest neighbour" you choose deliberately.
- **O-B6. Lightweight ADRs.** Add `docs/adr/NNNN-*.md`, one page each, for decisions such as "AI runs on its own capsule", "classifiers are rules", "AI writers lock", and "Jev requires explicit opt-in". Agent guidance should say: *if your change contradicts an ADR, stop and open a design issue.* That makes implicit decisions (B4) visible and cheap to respect.
- **O-B7. Seams as registries.** Wherever Sure already uses registries (provider adapters, rule actions, insight generators, assistant functions), parallel agent PRs rarely conflict and are easy to review. Extending the pattern to AI operations (S2) and config (S6) makes AI work equally parallel-friendly.
- **O-B8. CODEOWNERS for seams.** Request maintainer review on `Rule::Runner`, `Provider::Registry`/router, `config/sidekiq.yml`, `Enrichable`, and `db/migrate/*` that touch `rules`. This spends review effort where architecture can break and lets leaf PRs move faster.
- **O-B9. Agent-run maintenance.** The same agents that create duplication can remove it. File well-specified "consolidation" issues (S1–S10), each with acceptance tests from O-B1 and O-B2, and label them `good-agent-task`. Sequenced properly, they are low-risk and high-value work for the contributor pool.

### 3.3 Simplifications (process lens)

| ID | Simplification | Effect |
|---|---|---|
| **P1** | A single source of agent instructions: `AGENTS.md` plus `docs/llm-guides/`. Make tool-specific files one-line pointers, maintained by a CI check (the preservation map becomes a test). | Stops instruction drift (B8). |
| **P2** | A comment policy: *comments state constraints and why; history belongs in commits and ADRs.* Add it to `AGENTS.md` and to review. Optionally run a periodic agent sweep that turns narrative comments into ADR links. | Fewer stale comments (B5). Smaller diffs. |
| **P3** | A "design issue first" label for PRs touching the O-B8 seams. The PR template asks "which ADR does this follow or change?" | Makes B4 decisions explicit without slowing leaf work. |
| **P4** | Split hot files: `Family::Classification` concern, a settings permit list per section (or generated from S6), one locale file per feature area. | Fewer agent rebase conflicts (B9). |
| **P5** | A parity rule: an AI feature PR must cover every registered transport, or declare it unsupported (enforced by O-B1). | No more half-filled matrices (B3). |

---

## 4. Where the two lenses interact

| Architectural property | Rails cost | Agent-era multiplier |
|---|---|---|
| Duplicated per-provider workers | maintenance, bug fixes per cell | **every new feature copies the pattern**: debt grows with velocity |
| Implicit contracts (locks, lanes, consent) | needs tribal knowledge | **invisible to the agent**, so it is silently violated |
| Registries and declarative extension points | slight indirection | **ideal for parallel agents**: low conflict, easy review |
| Hand-written reference docs | go stale | **go stale faster**: generate them |
| Executable invariants | nice to have | **the primary way to steer agents** at 376 commits/month |
| Big central files | readability | **conflict hotspots** for concurrent branches |

The general rule: **in an agent-driven project, centralize mechanisms and decentralize declarations.** Make the shared parts (routing, structured output, batching, failure policy, config) singular and well tested, and make the varying parts (operations, prompts, schemas, rule actions, generators) small declarative files that are safe to copy.

---

## 5. Suggested sequencing

Ordered so that each step makes the next one safer for agents to carry out.

| Phase | Items | Why first |
|---|---|---|
| **Now (guardrails)** | O-B1 (parity, lane, router-cop, `family:` tests), O-B5 (one guide + recipes), O-B6 (first 4 ADRs), P1, P2, O-B8 | Cheap. Stops new divergence before consolidating old divergence. |
| **Next (foundations)** | S1 router, S6 config registry, S5 `AiJob` base, S7 enrichment policy, O-B2 contract tests, O-B4 generated docs | S1 and S6 remove the most drift. O-B2 is the prerequisite for S2. |
| **Then (consolidation)** | S2 structured-call primitive, S3 batching, S8 web-thread LLM calls to jobs, S9 classifier Run as rules, S10 / P4 file splits | Large, but mechanical once contracts and tests exist. Good `good-agent-task` material (O-B9). |
| **Product (decided by maintainers)** | S4 rule-pipeline phases, O-A1 cascade as product, O-A2 per-task models, O-A3 provenance UI, A11 consent policy, O-B3 eval gate | Changes visible behaviour or policy. Needs an ADR and a maintainer decision, not an agent PR. |

[05-ai-breaking-change-option.md](05-ai-breaking-change-option.md) sketches the same refactor with breaking changes allowed, and maps each change to the interfaces it breaks in [01 D5](01-ai-ml-workflow-map.md#d5-interface-register).

### Non-goals

- Don't introduce a general LLM framework (LangChain-style) or a new dependency. The S2 primitive is about 200 lines over the existing SDKs.
- Don't move Bayes or the matcher to a service, or persist models. In-memory training per run is a feature: no state to migrate, and evaluation is trivial.
- Don't block agent PRs on long design docs. ADRs stay one page, and recipes stay copyable.

---

## 6. Caveats

- This review is based on the traced workflow map and repository metrics, not on interviews with maintainers. Some "inconsistencies" may be deliberate trade-offs that are recorded in PR threads.
- The metrics are approximate (for example, co-author trailers count several per squash commit).
- The proposed router, structured-call primitive and config registry are directions, not designs. Each should get its own ADR, with the cross-transport contract tests written **before** the refactor.

---

## 7. Files to split

Moved to [06-ai-file-split-review.md](06-ai-file-split-review.md): which files cross MVC boundaries, span several resources, or collide across open PRs (F-H, F-M, F-R), and whether each should be split before, during or independently of this refactor.
