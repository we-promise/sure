# RubyLLM Workbench ↔ the AI plumbing redesign — comparison and recommendations

Status: analysis, 2026-11-17; **disposition applied the same day, after 2a (dbeebf14c) and 2b
(992bfdcd8) merged** · Companion to [`ai-plumbing-redesign.md`](ai-plumbing-redesign.md).
Subjects: [`yorzi/rubyllm-workbench`](https://github.com/yorzi/rubyllm-workbench) (cloned at
`~/src/rubyllm-workbench`, `3c9162d`, RubyLLM 2.2.0, Rails 8.1.4.1, Ruby 4.0.9) and the Sure
proposal (`docs/proposals/v0.8/`).

> **Read §0 first.** The 2a/2b recommendation mapping in §10–§11 was written before those two
> PRs merged and is historical. §0 records what merged, what landed, what is retired, and where
> each remaining recommendation now lives.

**Summary.** rubyllm-workbench is a single-user, local-first Rails reference app whose product is
*inspectable AI execution evidence*. The redesign is a multi-tenant family-finance AI layer whose
product is *consent, routing and safe degradation*. They share one decision — RubyLLM 2.2.0 with
`acts_as_chat`/`acts_as_message` on Sure-shaped tables — and diverge on almost everything else.
Workbench has already built, tested and shipped on 2.2.0 several things the proposal still has open,
deferred or designed on paper: the persisted-chat storage path, a lease fence that works alongside
the gem's claim, an owner-linked usage ledger, idempotent instrumentation, an approvals state
machine, a redacted exporter and a provider-free test policy. The proposal, conversely, answers
product questions workbench never had to (routing, consent, failover, lanes, configuration in the
database). The right move is not convergence: it is to pull workbench's proven building blocks
into the proposal's better architecture, and to keep workbench's evidence discipline out of the
hot path where it doesn't scale (10k-row categorization batches).

Recommendations are numbered R1–R24 and mapped to the proposal's sections. §0 records the
disposition after 2a/2b merged (2026-11-17); §10's table and §11's sequencing are historical
where they disagree with §0.

## 0. Disposition — what happened to the recommendations (2026-11-17)

2a and 2b merged (dbeebf14c, 992bfdcd8). 2c is #4775 (head `bd6345a26`, which carries one
recommendation — finish_reason and the cost/idempotency guarantees). 2d is #4765, 2e is #4771,
2f is #4892, all stacked on `refactor/ai-plumbing` with #4775 as 2c's branch. R13 shipped as
PR #5209. Two facts about the merged state matter for everything below:

- **The stack gathers on `refactor/ai-plumbing`, not `main`**, and all its PRs share it as
  their base.
- merged 2a decided **"Never create `ruby_llm_usages`"** (config/initializers/ruby_llm.rb,
  docs/llm-guides/ai-pipeline.md), retiring the premise of R1 while keeping its underlying
  question alive for PR 6: with RubyLLM 2.2 on the persisted chat, the gem writes ledger rows
  unguarded, and the merged Sure rule is to live with that rather than create the table.

| Rec | Disposition after 2a/2b merge | Where it went |
|---|---|---|
| R1 (one linked ledger) | **Retired by merged 2a.** The plan's §10 said PR 6 creates the table but never reads it; merged 2a went further and forbids creating it. The residual risk moved to PR 6: decide a strategy for the unguarded `ruby_llm_usages` writes of the persisted chat — create the table with an owner link (workbench's shape), or confirm on 2.2.x that the writes are tolerable. This decision gates chat acceptance, not code in 2c–2f. | PR 6 checkpoint / re-decide the plan §10 sentence |
| R2 (Attempt-shaped usage rows) | **Partially landed.** 2a writes one row per request with `call_id` + `status` (succeeded/failed/cancelled) and `tokens_unknown` in metadata, grouped per call on the page by `LlmUsage::Call`. `finish_reason` added in `bd6345a26`. `error_code` deliberately **dropped** (nothing produces one distinct from `error_class` + HTTP `status`, both already in `metadata`); `sequence` not added (`created_at, id` ordering suffices at one-batch-at-a-time). | Done in 2a/2c; no column before PR 7 |
| R3 (Cost provenance) | **Mostly landed the merged way.** 2a: provider-reported cost first, else `calculate_cost` (kept deliberately), unknown tokens → nil cost + `tokens_unknown`. 2c (`bd6345a26`) added: refused-before-billing requests are the gem's explicit `Tokens(0,0)` and stay **0/0/0 with 0.0 cost** (verified against `RubyLLM::Accounting::Usage#failure_tokens`); possibly-billed failures keep cost unknown; stored costs are summed as stored, never recalculated (test pinned with `calculate_cost` stubbed to raise). `cost_status` enum + `calculate_cost` deletion (R24.2/R24.3's exit) → PR 7, which carries the prices. | Cost provenance tests now in 2c; deletion in PR 7 |
| R4 (Subscriber discipline) | **Half landed; dedup retired.** 2a ships the central `Ai::Instrumentation::Redactor` (used by Langfuse/Usage/DebugLog), failure isolation (UsageSubscriber rescues to a log line; Langfuse warns), per-request rows, `request.ruby_llm`/`.ai` error attribution by call_id, and 2c attaches `finish_reason` from the `.ai` event to the answering row. A strict payload key allowlist was not adopted (the Redactor's recursive credential-masking is the contract). `event_key` dedup is **retired**: AS::Notifications is synchronous in-process, a subscriber cannot see the same event twice, and job retries re-bill honestly — dedup would hide spend, not protect it. | Redactor + isolation in 2a; allowlist as documented review contract |
| R5 (ExecutionContext) | **Done, by a stronger mechanism.** 2a's `Ai::CallContext` (Fiber storage) wraps `RubyLLM.workflow` and `RubyLLM.with_usage_owner`, carrying feature/call_id/family/endpoint/model/correlation_id into every RubyLLM event and Sure's `.ai` events, with `correlation_id` on the rows. | 2a (call_context.rb + test) |
| R6 (write-point lease fence) | **Not started.** PR 6 material. Unchanged. | PR 6 |
| R7 (no in-place history filter) | **Not started.** PR 6 material. Unchanged — but note merged 2c does trim against the persisted transcript nowhere, so R7 is now just a PR 6 acceptance criterion, not a rescue. | PR 6 |
| R8 (internals quarantine) | **Not started.** Nothing in 2c–2f touches private RubyLLM API. | PR 6 |
| R9 (approvals state machine) | **Not started.** Still "PR 6 for records + closure semantics, PR 8 for UI". Unchanged; no precedent in 2b, which shipped consent only. | PR 6 / PR 8 |
| R10 (cancel closure semantics) | **Not started.** | PR 3 / PR 6 |
| R11 (parallel-call policy) | **Not started.** `parallel_safe?` has no Sure analogue yet. | PR 6 (or its own PR) |
| R12 (idempotency regression) | **Done in 2c** (`bd6345a26`): crash-after-commit no longer double-applies — the enrichment lock wins, now pinned by a re-apply test in `auto_categorizer_test.rb`, alongside 2c's `answered_before` chain and give-up-notifies-requester semantics. | 2c (bd6345a26) |
| R13 (network-deny meta-test + CI guard) | **Done as PR #5209** — `test/lib/ai_network_policy_test.rb` (error-level refusal + a full-suite source scan) + `script/ci/deny_provider_http.rb` wired into both unit and system test jobs. Verified to fail the build with an injected `WebMock.allow_net_connect!`. | PR #5209 |
| R14 (redacted reproduction export) | **Not started.** | PR 8 |
| R15 (recovery/sweeper) | **Reframed** from "a generous stale-Run sweeper for AI jobs" to PR 3/6 (chat turns and agent deliveries are the only AI rows in `running`; background features have no Run row). | PR 3 / PR 6 |
| R16 (checksum staleness) | **Not started — PR 7.** Sure has no per-vector checksum; the re-index-on-changed-model flow gives the staleness problem its shape there. | PR 7 |
| R17 (Anthropic `output_config` gate) | **Active, unchanged.** Anthropic `with_schema` remains gated on a funded live check; the transport contract suite and `test/models/ai/live/` cassettes exist for exactly this. | 2c (as planned) |
| R18 (don't copy per-case Runs / Solid Queue) | **Holds.** Unchanged. | (kept) |
| R19 (eligibility UX on routes page) | **Not started — PR 7.** The routes page doesn't exist yet; the guard's affordance is 2b's `AiFeatureGuard`, which only answers availability. | PR 7 |
| R20 (probe logs the real answer) | **Half landed in 2a.** The merged probe is the production path now (synthetic PDF, strict-tool check, tool-call validation, rejects blank chat answers — #5180/#5181) and the compatible transport already **verifies the answering model** (`check_answering_model!`, `same_model?`, added in 2a). What's missing: context-window confirmation (preset `context_probe`) and recording confirmed capabilities to the model record. | 2a (partial); PR 7 (rest) |
| R21 (NoAiSmokeTest, request-level) | **Not started.** §16 scope, PR 8. | PR 8 |
| R22 (2.2.0 baseline evidence) | **Open — 2f.** ruby_llm is pinned `~> 2.1` on 2c; 2.2 lands in 2f (#4892). | PR 2f / release notes |
| R23 (frozen manifest for shadows) | **Done in 2d** (944fad71a): `Ai::Shadow.fingerprint` (per-item SHA-256 + context digest, item payloads never leave the process), skip-on-edit for items and context, never applied, `sidekiq_options retry: false`, deadlocks discarded, results only through `Ai::Comparison`. | 2d (944fad71a) |
| R24 (non-goals / trap) | 24.2 **enforced in 2c** (unknown-cost rows pinned); 24.3 no-reprice pinned in 2c; 24.1 stays a 2f release-note line. | 2c (bd6345a26); PR 2f |

**Superseded §10–§11 notes.** The sequencing table (§11) predates the merge: its "2a" row
(R3/R4/R5/R13) is now "R3/R4/R5 in 2a, R13 in #5209", and its "2b" row (R19/R21) moves entirely
to PR 7/PR 8. §13's assessment stands, with one correction: R1 is retired, not pending.

**Stale plan text this supersession exposes** (worth a #4440 follow-up edit): §10's
"`ruby_llm_usages` is created in PR 6 … they keep the table present so attempts persist" is now
superseded by merged 2a's "Never create `ruby_llm_usages`"; either the plan gets a new PR 6
decision note or the ledger rows stay unguarded under the 2.2 persisted chat, which is the
remaining unaddressed leak in the 2.2 upgrade story.

## 1. What each project is

| | rubyllm-workbench | Sure AI plumbing redesign |
|---|---|---|
| Users | One developer, local | Families, a family admin, a self-hoster, a multi-tenant admin |
| Tenancy | None (Projects are local groupings) | Family tenancy + member switches, consent, keys, cost caps |
| Product | Run inspector, exportable evidence, learning panels | Categorization/merchants/chat/PDF that just works, consented |
| Failure model | Show the failure durably; never replay silently | Route around the failure (failover, escalation, down marks) |
| Config | ENV/credentials, one initializer | Database tables, presets, `AI_CONFIG`, legacy ENV path |
| AI calls | Through RubyLLM, always; no provider SDK elsewhere | Same rule, enforced by cops and capsule-only transports |
| Status | v0.1.0 shipped; 2.2.0 upgrade green locally | Proposal; spike done; PR 2a–2f underway |

## 2. Execution shape

### Workbench

Every provider operation becomes a **Run** (person-level, snapshot-frozen) with **Attempts**
(one per provider/model request, `sequence` uniqueness per run). Controllers → executor
(`Ai::RunExecutor`, `AgentRunExecutor`, …) → job (`ChatResponseJob`, `AgentRunJob` as
`ActiveJob::Continuable`) → executor class. Jobs carry `run_id` only. Inputs (prompt, tools,
tool options, conversation context, provider tools) are frozen into `input_snapshot_json`; later
edits never rewrite history. A drift check (`Ai::ChatContextSnapshot`) refuses to call the provider
if the chat changed after queueing.

### Proposal

**`Ai::GenerationJob.perform(feature, args)`** with `ids` args, a requester rebuilt per job, one
batch per call, `remaining` re-enqueued at the back of the queue — no Run/Attempt record per
batch, cost tracked per request in `llm_usages`. Chat goes through `Ai::Conversation` on RubyLLM's
persisted chat. Same instinct (job carries ids, rebuild the domain object), deliberately lighter
records: no Run row per categorization batch.

### Verdict

The proposal's granularity is correct for high-volume background features; workbench's is correct
for interactive and auditable ones. See R2 and R3.

## 3. Chat on RubyLLM 2.2's persisted chat

Both adopted `acts_as_chat`/`acts_as_message`. Workbench runs it in production paths today
(chat and agent steps), on Rails 8.1.4.1, with the following load-bearing pieces the proposal is
still deciding:

**a. The lease fence backstop.** `Message#before_save` (`assert_agent_execution_lease`) raises
`ExecutionContext::ExecutionLeaseLost` when a stale owner token/generation writes to the chat.
`AgentRunJob` claims the Run with a random token + increasing generation + 5-minute lease and
heartbeats every 15 s during long provider calls; every transcript write, usage row, stream and
tool write is checked against the lease **inside the Run's row lock**. The gem's persisted chat
has its own claim (60-second lease, per-tool claims), but workbench does not trust it alone for
multi-step agent turns and certainly not for Sure's cross-process cancel.

Proposal §8.4 leaves two things open for PR 6's spike: whether Sure drives `complete` or a loop of
`step` (the claim covers one move, not a turn), and where `History` (same-slug drop rule, Gemini
placeholder signature, budget trimming) plugs in. Workbench's answer to both, tested on 2.2.0:

- fence at the **write point** (`before_save` on Message), not only at claim time — a stale writer
  cannot append or rewrite history even if the driver shape changes;
- **don't mutate history in place at all** for ordinary trimming — workbench keeps every round as
  message rows and rebuilds requests from them; its next-turn prefix test asserts byte-prefix
  stability across a reload. The plan's `#5078` replay-prefix test is the same idea, ported.

**b. Correlation into RubyLLM's instrumentation.** `Ai::ExecutionContext`
(`ActiveSupport::CurrentAttributes`) publishes `run_id`/`attempt_id`/lease token+generation; the
`.ruby_llm` adapter (`Ai::RubyLlmInstrumentation`) joins provider-side `chat.ruby_llm` et al. to the
Run **in the same process**, whitelists scalar payload keys, applies the lease fence inside
`run.with_lock`, and never fails the call when recording fails (logs at debug and continues).
`RUN.ruby_llm_usages` links the gem's persisted usage rows to the Attempt via
`has_many :ruby_llm_usages, as: :owner`.

The proposal's `Ai::CallContext.job` (2c correlation id) and `UsageSubscriber` solve the same
problem; workbench proves the mechanism end-to-end on 2.2.0, including
`usage.ruby_llm` per request and an `owner` link.

**c. RubyLLM's private surface is quarantined.** `Ai::RubyLlmInternals` lists the only two private
APIs workbench touches (`persist_usage_entry` wrap — a per-attempt usage fence; and
`record_tool_call_decision`), with an offline contract test that fails on every gem upgrade. The
two 2.0 monkey-patches were removed on the 2.1 pin.

**d. Storage rows are shared with the gem.** Workbench's `chats`/`messages` carry the gem's
columns from its migration (`create_ruby_llm_records.rb`); the proposal's plan (Gemini signatures
moving into `ruby_llm_tool_calls`, `ruby_llm_queued_messages`, `ruby_llm_usages` in PR 6) matches —
workbench is evidence that this migration shape works.

## 4. Evidence and accounting

| Concern | Workbench | Proposal |
|---|---|---|
| Request-level usage | `Attempt` columns + gem's `ruby_llm_usages` (owner-linked) | `llm_usages` row per `usage.ruby_llm`, grouped by `call_id`; ledger created but **never read** (§10) |
| Cost | `reported` / `recorded` / `estimated` / `unknown`; never repriced, history not backfilled; failed zero-token requests stay `unknown` | reported cost, else model price estimate; `calculate_cost`/`infer_provider` deleted; `cost_status` not specified |
| Run/attempt provenance | `input_snapshot_json`, `app_version`, `ruby_llm_version` on every Run | none (jobs log, `llm_usages.metadata` has route + error_class) |
| Shadow/comparison | `EvaluationComparison/Execution` per case; provider Batch verified against frozen case manifest before collection (`Ai::EvaluationBatchResults`) | `Ai::Comparison` per item, agreement rates on health page; Batch only via `ai_batch_fairness_test` |
| Diagnostics export | `Ai::RunReproductionExporter` — redacted, prompts/transaction text never included | "Copy diagnostics" — planned (§13) |
| Event catalog | `LifecycleEvent` with `event_key` dedup (idempotent) and allowlisted payload | Notify-subscriber writes directly; no dedup, no allowlist |

## 5. Tools, approvals, cancellation

**Parallel-call policy** (workbench): per-Project opt-in, `ToolExecutionPolicy` checks (1) registry
entry `parallel_safe?` for every enabled tool, (2) model capability for parallel calls,
(3) explicit Project setting — else fall back to sequential with a recorded `fallback_reason`.
`project_snapshot` is parallel-safe; `save_run_note` is not. The decision is frozen into the Run
snapshot.

**Approvals** (workbench): `Assistant`-style tools are code-registered only; a pending call creates
`ToolInvocation(requested → running)` + `Approval(pending)`, the Run goes `waiting_for_approval`,
and the Approve/Deny path is durable across processes. Denial writes a provider-visible tool
result; `remote_tool_outcome_unknown` (an approved remote call with no saved provider result)
**blocks the chat** with an explanatory message; cancel closes pending approvals and in-flight tool
invocations inside the Run's row lock. Approval continuations re-enqueue the same job; the prompt
is never re-sent.

**Cancellation** (workbench): `Run#cancel!` under `with_lock` cancels attempts, resolves pending
approvals, cancels active tool invocations, calls RubyLLM's `chat.cancel` for chat/agent
operations, and is refused once terminal. UI stop buttons map to `DELETE` on the resource.

Proposal §12 is cooperative-only and defers ("approve and deny UI is a feature of its own, not
part of this plan"; "the gate's interrupt, not a stop, re-sends the request"). The gap list for
the proposal is exact: no loss of the recorded approval flow, no `remote_tool_outcome_unknown`
equivalent, no closure of in-flight tool invocations on cancel.

## 6. Retrieval and evaluation (where workbench is genuinely deep)

- **Vector store**: default application cosine over blob columns; opt-in `sqlite-vector` adapter
  with derived per-dimension tables (rebuildable, not in `schema.rb`); embeddings unique per
  `(chunk, model)` keyed by content checksum — stale vectors are detected and skipped, and
  re-embedding is a first-class action.
- **Degradation is explicit**: `Search` returns lexical evidence with the requested mode and the
  *reason* when semantic is unavailable; the page says so. No silent downgrade.
- **Grounded answers**: retrieve → frozen corpus/vector revision → generate with native
  `with_schema` → validate exact-quote citations under a completion lock → refuse when no chunk
  matches. Usage is owned (native ledger rows attributed to the retrieval Attempt); nothing is
  replayed for evaluation — saved JSON is evaluated in independent Runs.
- **Evaluation datasets**: revisioned; comparisons are per-case Runs + optional judge; provider
  Batch results are matched against the frozen case manifest before collection.

Proposal §5.5's "a changed `embed` route never moves or deletes documents silently" and §8.1's
extraction checks (balance reconciliation, citation-style quote checking is *not* present there,
though balance/date/coverage checks serve the same role) are directly informed by this work.

## 7. Configuration and provider setup

Workbench: one initializer maps 33 known `ANTHROPIC_*`/`OPENAI_*`-style ENV keys to RubyLLM config
(only present values), plus `Rails.application.credentials` for keys; `Ai::ModelCatalog` checks
each registry model against its provider class's `configuration_requirements` and reports
`needs configuration` with the missing keys; agent launches refuse ineligible/unconfigured models
with actionable messages (`Ai::AgentModelEligibility`). Free-registry lag (models listed but not
served; mislabeled capabilities) is a documented caveat with a picker warning.

Proposal: database tables (`ai_endpoints`/`ai_models`/`ai_routes`), presets, digest-based
`AI_CONFIG` loading, all-or-nothing source rule, `LegacyEnvConfig` shim, probes per model with
capability confirmation, `context_probe` for llama.cpp/Ollama. This subsumes everything workbench
does, and fixes workbench's remaining holes (registry lag, no endpoint/model tables at all, no
per-route overrides). Workbench is not the model to copy here — except the *initializer hygiene*
(single explicit mapping, no stray `ENV` reads) and the *eligibility check with a human message*
(§8, R7).

## 8. Testing and release discipline

Workbench: ordinary `bin/rails test` never calls a provider (WebMock, loopback allowed); a
**network-policy test** (`test/lib/ai_network_policy_test.rb`) fails if a test can reach the
network; live acceptance is opt-in (`bin/dogfood`, serialized, `RUN_LIVE_AI=1`, `AI_TEST_PROFILE`);
CI builds assets and runs system tests headless; provider keys never enter fixtures, logs or
screenshots; `script/diagnostics/` reproduces suspected gem bugs offline without touching network;
releases ship with a written capability matrix and dated live evidence, and "unknown costs remain
unknown" rather than fabricated.

Proposal §17 is richer on the product side (architecture tests per invariant, cops,
transport contract suites on recorded cassettes, `ai-live` label, recorded evals as a merge gate)
but has no **meta-test that fails when a test itself performs HTTP** — workbench's
`ai_network_policy_test.rb` — and no explicit "provider keys never in CI" evidence standard like
workbench's `bin/ci` denial script (`script/ci/deny_provider_http.rb`).

## 9. Where each is ahead (fair ledger)

**Proposal ahead, workbench silent or absent:**
- Lanes/gates/sequencer, chat-first local scheduling, interruption of background calls — nothing
  comparable in workbench (it runs everything on Solid Queue, FIFO).
- Router, consent (two-level), allowed endpoints, own keys with cost caps, member switch,
  availability reasons, "AI unavailable" UX, NoAiSmokeTest.
- Config in the database with all-or-nothing source rule, presets, `AI_CONFIG`, legacy ENV
  migration, `ai:export_config`.
- BatchSlicer-style token-aware batching, JSON-mode fallback chains, transport per protocol, Jev,
  OCR, vector-store fixes, per-attempt time budgets, down marks, failover/escalation, shadow runs.
- Rich error taxonomy (`Timeout`/`RateLimited`/`NoCredit`/`ModelMissing`/…) vs workbench's three
  buckets (`application_error`/`provider_error`/`transport_error`).
- MCP-specific handling, Pipelock/proxy discipline.

**Workbench ahead, proposal open, deferred or paper-designed:**
- Working lease fence on top of the gem's claim (proposal: open PR 6 spike).
- Owner-linked `ruby_llm_usages` and cost provenance that survives upgrades (proposal: ledger
  written, never read; cost provenance unspecified).
- Idempotent instrumentation with failure isolation (proposal: subscribers write directly).
- Approvals UI + `remote_tool_outcome_unknown` + cancel closure semantics (proposal: deferred).
- `Ai::RubyLlmInternals` quarantine + upgrade contract test (proposal: scattered notes).
- Redacted reproduction export implementing "Copy diagnostics" (proposal: planned §13).
- Network-deny meta-test + explicit CI denial (proposal: cassettes + label, no meta-test).
- Knowledge-grade staleness handling (checksum key, unique per chunk+model) for the re-index and
  "changed embed route" problems (proposal §5.5: confirmation UX, no staleness mechanism).
- Live evidence that the 2.2 persisted chat + approvals + outbox work in the same process as
  Solid Queue, ActiveJob::Continuable, Turbo Streams and SQLite — i.e. the exact stack the
  proposal targets (Sure: Postgres + Sidekiq, but the gem-side semantics are identical).

**Both agree:** every provider call through RubyLLM; no provider SDKs in app code; no AI on web
threads; failover belongs to the app, not `with_fallbacks`; prompts are data in files, reviewed as
code; frozen snapshots so old requests are reproducible; recovery rather than silent replay; cost
recorded, never invented; tests must not call providers by default.

## 10. Recommendations

**R1 — Read the ledger you create; collapse the two usage tables.**
Proposal §10 decides PR 6 creates `ruby_llm_usages` but Sure "never reads it", while
`UsageSubscriber` writes `llm_usages`. Two row-per-request tables that cannot be joined will drift
— precisely the 7-way duplication §1 exists to kill. Recommendation: add a polymorphic
`owner` reference (Attempt/Run) or a shared `call_id` on the gem's ledger rows via the
`wrap_usage_recorder` seam (workbench `Ai::RubyLlmInternals`), so `llm_usages`/`ruby_llm_usages`
join 1:1. Longer term, pick one store for request-level truth; keep `LlmUsage` only for the
family-facing page's monthly rollups. At minimum, link owner (one column) so the rows are not
orphans and support tickets can answer "which request cost this?".

**R2 — Keep Attempt-style `sequence`, but on `llm_usages`, not a new table.**
The proposal's `call_id` + ordered requests is right; name the per-request row `attempt`-shaped:
`sequence` per call, `provider`, `model`, `status (succeeded/failed/cancelled)`, `finish_reason`,
`error_code`, token columns incl. cache, `reported/recorded/estimated cost` and `cost_status`.
This is Attempt minus the Run FK — the proposal can skip Run rows for background features without
losing per-request ordering or cost provenance (workbench proves the shape).

**R3 — Adopt `CostNormalizer` verbatim, with its provenance rules.**
`reported → recorded → estimated → unknown`, never repriced, history never backfilled, zero-token
failed requests stay `unknown`, estimate only when tokens exist. Delete the plan's
`LlmUsage.calculate_cost` as proposed, but carry `cost_status` (or equivalent) into §10's
`llm_usages` so the health page's "invalid-output rate" and cost caps (§4.2) read honest data.
Agent calls with no tokens: record `unknown`, as workbench does — zero cost, shown as such.

**R4 — Give `§10` subscribers the workbench `LifecycleEvent` discipline.**
Add (a) `event_key`-style dedup so a retried job never double-counts a request,
(b) an allowlist of payload scalars shared by Langfuse/DebugLog/Usage subscribers (one helper —
the plan's "one secret-redaction helper" made concrete: `Ai::ErrorText.redact` exists and is
tested), and (c) failure isolation: a subscriber raising must never fail the AI call or the job
(workbench rescues to debug log). The plan's §17 tests should include "a subscriber that raises
does not change the AI call's outcome".

**R5 — Adopt `ExecutionContext` as the call context.**
`Ai::CallContext` (2c) and `Ai::ExecutionContext` (workbench) are the same idea; take the
`CurrentAttributes` shape with `run_id`-equivalents (`call_id`, `job_id`), attempt sequence, and
lease token/generation when present. It is the only pattern known-good on 2.2.0 for joining
provider-side `usage.ruby_llm` to the caller, including from tool threads spawned by RubyLLM
(`concurrency: :threads`) — workbench observed that those threads inherit nothing automatically,
which is also why `SureTool` keeps the lane explicitly. Both mechanisms are needed;
`ExecutionContext` covers the subscriber, the lane covers interruption.

**R6 — PR 6 should not build on the open spike question alone; fence at the write point.**
Before PR 6 finalises its driver, port `Message#before_save`'s lease fence (works today on Sure
too: `chats`/`messages` will carry RubyLLM's columns) so a stale or interrupted owner cannot
append rows, corrupt the next turn's prefix, or win a `waiting_for_approval` → `running`
transition. Then the "claim covers one move, not a turn" question becomes an optimisation, not a
correctness boundary. Pair with a heartbeat inside long provider calls (workbench renews every
15 s; the gem's claim renews on steps but a 5-minute cloud read between renewals is possible).

**R7 — Close PR 6's `History` question by *not* filtering in place.**
Workbench ships the persisted chat without any history-trim hook: every round is a message row,
requests are rebuilt from rows, and trimming is an application decision made at enqueue time
(prompt packing), not inside the gem's sync. Recommend the proposal:
1. drop the same-slug rule's in-place rewrite of sent history; instead never send state that
   doesn't belong (compute the outgoing message array in Sure — the gem already sends what is in
   its tables; Sure controls what persists via provider-state stripping at persist time or via a
   narrow upstream seam);
2. ask upstream for the one seam it needs (read/filter messages before send), as the plan already
   contemplates — but treat it as an optimization, not a prerequisite;
3. port workbench's reload-stability test (byte-prefix across a reload mid-turn) alongside the
   ported #5078 test.

**R8 — Quarantine every private RubyLLM API in one module with a contract test.**
Create `Ai::RubyLlmInternals` (name is taken and documented in workbench) listing *each* internal
seam the plan touches — `persist_usage_entry` wrap, `record_tool_call_decision`,
`with_context_budget`, `compact`, claim renewal, `ToolRoundLimitError` handling — each re-checked
on every gem bump by one test. This is the single cheapest risk reduction available to PR 6 and it
also satisfies the §7 "re-check on upgrade" note with an executable artifact.

**R9 — Pull the approvals state machine into scope.**
"Approve and deny UI is a feature of its own" strands every `requires_approval` write tool: the
turn ends `:awaiting_approval`, and without a decision path the conversation is dead. Workbench
shows the minimum viable shape, all of it needed regardless of UI: `ToolInvocation` transitions
(`requested → running → succeeded/failed/denied/cancelled`), `Approval` record with expiry, drain
on cancel/fail **inside the Run's row lock**, continuation job with the original prompt never
re-sent, and the `remote_tool_outcome_unknown` rule (an approved remote call with no saved result
blocks the chat; nothing else may start). Recommendation: PR 6 ships the invocation/approval
records and the cancel-closure semantics; PR 8 ships the UI; the *policy* (write tools
require approval, undecided ends the turn) is in scope for the plumbing.

**R10 — Add cancellation side effects to §12.**
Extend "cooperative, nothing is killed mid-write" with workbench's closure semantics: on cancel
of a run/suggested/chat: (a) pending approvals resolve to `cancelled`/`expired` with an actor,
(b) in-flight tool invocations are marked cancelled, (c) a non-streamed request already sent
cannot be aborted — its result is discarded **and the `ToolInvocation` is marked
`remote_tool_outcome_unknown` when the tool is remote**, not silently dropped, (d) usage is
recorded (plan already requires this). And a stop must be re-queued once per thread-safe rule —
workbench's `DELETE` on the resource matches §15's controller shape; keep it.

**R11 — Adopt `ToolExecutionPolicy`, not just `SureTool requires_approval`.**
Approval asks *whether* to run a write; it does not answer *whether these calls may run in
parallel*. Workbench's policy: per-Project sequential/parallel opt-in ∧ every enabled tool
`parallel_safe?` ∧ model capability; otherwise fall back to sequential **with a recorded
reason** and freeze the decision into the snapshot. Map onto Sure: per-Project (or per-family
advanced setting) parallel opt-in, `parallel_safe?` on `Assistant::Function` subclasses,
derived from capability registry, snapshot into each requester's job args. This is independent of
#4628's read/write classification and unblocks parallel tools for chat once a supporting provider
appears (live parallel returns are unverified in workbench too — mark it so).

**R12 — `event_key`-style idempotency + failure isolation for jobs, not only events.**
Workbench keys events (`provider:<notification_id>`); the proposal should also make
`Ai::GenerationJob` re-enqueues idempotent end-to-end: a job that crashes after applying a batch
must be safe to re-run (plan already leans on enrichment locks; state it in §9's "no idempotency
promise" paragraph and add a test), and `Ai::ShadowJob`'s fingerprint rule (digest mismatch →
skip, never compare across edits) is the same instinct — reuse the helper for both.

**R13 — Add the network-deny meta-test and a CI denial script.**
Copy `test/lib/ai_network_policy_test.rb`'s assertion style (no socket/HTTP client may touch a
non-loopback host in any test) and `script/ci/deny_provider_http.rb` as a CI gate. The proposal
has cassettes + `ai-live` label but nothing that *fails when someone adds a test that calls a
provider*; workbench demonstrates this failing-first and costs one file.

**R14 — Base "Copy diagnostics" on `RunReproductionExporter`.**
The exporter already: copies a Run as redacted JSON (prompt, tools, provider/model, durations,
errors) with prompts hidden unless explicitly requested, allowlisted keys, and a guarantee that
keys/headers/family data are never included. The proposal's diagnostics block (§13) lists nearly
the same fields; build it on the exporter's redaction tests (diagnostics test in §17 becomes a
superset). Add the exporter's local-host-name replacement and you're done.

**R15 — Give every job class a recovery path; add a stale-Run sweeper.**
Workbench ships recovery jobs for media, speech, evaluation batches, native evaluations and grounded
answers (each finds work whose lease expired/job vanished and finishes or fails it inspectably).
The proposal re-enqueues on `Busy` and retries on `RateLimited`, but has no sweeper for a process
that dies mid-`running` with a local endpoint unreachable and no retry (e.g. `discard_on
Ai::Error::Refused`). Add a recurring `Ai::StaleRunRecoveryJob`: rows in `running` past a
threshold get their requester's `ai_failed` (or `ai_finished` replay) applied. Without it, a
cancellation storm or a crashed worker strands `WaitingForApproval` forever.

**R16 — Knowledge lane: adopt checksum-keyed embeddings and "stale vectors are skipped" verbatim.**
The proposal's "a changed `embed` route never moves documents silently" needs a mechanism, not
only a confirmation dialog: persist `content_checksum` per vector, verify before comparison,
re-embed on mismatch, skip stale reads (workbench). Same for the §7/PR 7 "dimensions don't
match" failure mode — detect by checksum/dimension row, not by `InvalidOutput` after the fact.
Also adopt the degradation-with-reason pattern for `Search` MCP fallback (`search_family_files`
falling back to metadata search already says why — keep it, and render it the same way on the
page).

**R17 — Checkout `with_schema` failure evidence before Anthropic PR 2c go/no-go.**
Workbench's live evidence: OpenRouter free models were flaky but delivered verified flows; the
provider-free suite passes; `with_schema` is the call in `StructuredExecutor` and is required by
the evaluation judge flow. The plan gates Anthropic `output_config` on "a live check with a
funded key" — correct. Keep the same live-blocked-but-tested-offline posture: stubbed tests +
one recorded cassette + `ai-live` for the merge, exactly as `#4513` already requires.

**R18 — Do not copy per-case Runs for background generation, and do not copy Solid Queue.**
Categorization on a 10,000-row import must not create 10,000 Run rows; the proposal's
`llm_usages` per request + requester hook is the right weight. Similarly, `Fiber` runners and
`limits_concurrency` both lost in workbench's environment and in the spike — keep Sidekiq +
lanes. The lesson is in the inverse: workbench's *lease* is cheap and small (one row, two
columns, a heartbeat); adopting its fence (R6) costs the same and buys the same guarantee.

**R19 — Ship the eligibility check and the human message, not just the router.**
Workbench's `Ai::AgentModelEligibility` + `find_entry(...).configured` produces
"This Agent model is not runnable yet. Configure OPENAI_API_KEY first." The proposal's
`Ai::AgentModelEligibility` analogue (`app/services/ai/agent_model_eligibility.rb` in the
workbench; `Ai::ModelCatalog` there) has no Sure counterpart — the closest is `Ai::Availability`
with reasons. Add the configured-check UX to the routes page (the admin's route entry names an
unset preset key → `:key_missing` before any call), which §5.3/PR 7 already hints at but does
not spec.

**R20 — Tighten §13 probes with workbench's "capability + configuration" double check.**
A probe that passes while the feature can't run is drift bug 6 in a new costume. Workbench shows
the shape: probes exercise the *production* transport (plan agrees) **and** the feature's
declared capability; plus a model-name comparison (LM Studio serves a different model with 200 —
plan has this for context window; extend the same check to "the model the server loaded is the
model we asked for" on every probe). Record the confirmed capabilities into the model record so
`needs` checking in the router can distrust declarations the probe contradicted (plan says "the
probe catches a declaration that's wrong" — make it write that fact down, not just warn on the
page).

**R21 — Adopt workbench's demo isolation for `NoAiSmokeTest`.**
Workbench's `Workbench::DemoMode.enabled?` nils every provider config and gates write paths;
`test/integration/read_only_demo_test.rb` proves crafts can't enqueue or call. The proposal's
`NoAiSmokeTest` is a page visit; strengthen it to a request-level test: with no endpoints, no
route may enqueue a job, no transport is constructed, no tool runs — the same assertion class
workbench runs as `read_only_demo_test.rb`. Cheap, and it is the regression net for drift bug 1's
cousins (an `@llm_available`-style leak).

**R22 — Keep the 2.2 upgrade evidence discipline as-is; workbench owes you the numbers.**
507/509 runs green on 2.2.0 with zero live requests; system tests green; only the internals
module remained. When Sure bumps to 2.2.x, pin and diff against this exact baseline: the two
known gem-shape risks in the proposal (persisted-chat claim across steps; `History` hook) are
already the two seams R6/R7 put behind Sure's own fence, so an upgrade cannot strand a turn.
Recommend the upgrade note cite the workbench evidence explicitly.

**R23 — Shadow runs: borrow the frozen-manifest rule from provider Batch.**
Workbench refuses to collect provider-Batch results whose submitted-chat manifest differs from
the frozen cases (`Ai::EvaluationBatchResults`), rather than trusting delivery. The proposal's
shadow job rebuilds items from ids "read as they are now" and skips digest-mismatch items — the
same rule, applied per item. Extend it to the *rest of the input* digest (plan already skips on
it — good) and to the tool definitions/provider tools in the snapshot, so two shadows never
compare across a mid-flight tool-change. And because shadow rows are never applied, apply
`event_key`-style dedup (R4/R12) so a re-enqueued shadow job doesn't double-write `Ai::Comparison`.

**R24 — Two concrete non-goals to steal, and one trap.**
(1) Non-goal steal: workbench's `docs/CAPABILITIES.md` + dated live-evidence matrix as the
release artifact for PR 2f — the proposal already wants e2e on free models; write outcomes into
the same matrix format. (2) Non-goal steal: workbench's "unknown costs remain unknown" rule —
when a provider reports no cost, record `unknown`, never an estimate, and say so on the usage
page (§10's `estimated_cost` path must keep this distinction). (3) Trap: workbench repriced
stored costs once and understated search costs; it documented the defect and stopped repricing.
The proposal deletes `calculate_cost` outright, which is the same call made cleanly — keep the
rule and its test (`ruby_llm_usage_ledger_test.rb` is the workbench analogue; add its sibling to
`ai_usage_subscriber_test`).

## 11. Suggested sequencing (historical; see §0 for what landed)

| PR | Recommendations |
|---|---|
| 2a | R3 (CostNormalizer), R4 (subscriber discipline), R5 (ExecutionContext), R13 (network-deny meta-test) |
| 2b | R19 (eligibility UX), R21 (NoAiSmokeTest as request-level test) |
| 2c | R1/R2 (ledger linkage + Attempt-shaped rows), R8 (RubyLlmInternals quarantine), R12 (idempotency), R24.3 (unknown-cost test) |
| 2d | R23 (frozen manifest + dedup) |
| 2e | R16 (checksum staleness), R15 (stale-work sweeper), R20 (probe double check) |
| 2f | R22 (2.2 baseline evidence), R24.1 (evidence matrix) |
| 3*  | R10 (cancel closure semantics), R15 (recovery jobs) |
| 4   | R6 (write-point lease fence), R11 (parallel policy), R18 (do not copy Runs/Solid Queue) |
| 6   | R6, R7 (no in-place history filter), R8, R9 (approvals state machine + remote_tool_outcome_unknown) |
| 7   | R19 (router-time configured check on routes page), R20 (probe writes confirmed capabilities) |
| 8   | R9 (approval UI), R15, R24.2 (unknown costs on usage page) |

## 12. What not to import from workbench

- **Run/Attempt per operation.** Too heavy for categorize-at-scale; keep for chat, bill setup, PDF
  and agents only if every UI surface reads them — otherwise `llm_usages` + requester hooks carry
  the weight (R18).
- **The evidence catalog as a hard gate.** Workbench can afford "instrumentation never fails the
  call" only because it logs and moves on; the proposal must keep the same rule but not add
  cross-request verification (shadow digest checks already cover that).
- **SQLite/Solid Queue.** Single-user pragmatics; the proposal's Sidekiq/lanes decision stands.
- **`Ai::ExecutionContext` for lease fencing alone** — workbench's fence works because writes go
  through `before_save`; Sure's background jobs write outside messages, so the fence must sit in
  the requester's `with_lock`/job code, exactly as `Run#finish_running_execution!` does in
  workbench.
- **The absence of routing, consent and config-in-DB.** Any temptation to "just read ENV like the
  workbench does" re-creates the 7-way drift the plan exists to remove.

## 13. Net assessment

The proposal's architecture (router + lanes + config tables + consent) is the right frame and
workbench has nothing to teach it there. Workbench's contribution is **operational**: it is a
running laboratory on exactly the gem version and Rails version the proposal ships, and its hard
won, tested decisions — the 2.2 persisted chat with a write-point lease fence, the linked
persisted-usage ledger, idempotent allowlisted instrumentation, the approvals/cancel state
machine, the diagnostics exporter, the provider-free test policy, and the rule that unknown costs
stay unknown — are the difference between "adopted RubyLLM 2.2" as a claim and as a fact. The
recompositions above are all additive; none demands redesigning §5–§11. The two with real scope
implications are R9 (approvals state machine into PR 6 scope) and R1 (one usage table, not two
that can't be joined). Both are, in workbench's experience, much cheaper to decide now than after
2a–2f and PR 6 land.
