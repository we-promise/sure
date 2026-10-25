# ADR-0001: One router for every AI call, adopted incrementally

| | |
|---|---|
| **Status** | Proposed, 2026-10-25 |
| **Deciders** | we-promise/sure maintainers |
| **Context document** | [RFC: AI and ML in Sure v0.8](rfc-ai-ml-v0.8.md) |
| **Checked against** | `main` @ `445b668d2` (2026-10-25) |

## Problem

[01](01-ai-ml-workflow-map.md) maps 24 AI and ML workflows, and about a dozen of them call OpenAI, an OpenAI-compatible server, Anthropic or Jev. Each feature decides for itself whether AI is available and which provider and model to use: three resolution paths, `Chat.default_model`, the vector-store default and about eight availability checks ([01 B1](01-ai-ml-workflow-map.md#b1-provider-resolution), [02 A1](02-ai-architecture-review.md)). Behind them, 12 provider worker classes each re-implement structured output, retries, usage and tracing, and the declared provider interface no longer matches the code ([01 D5.6](01-ai-ml-workflow-map.md#d56-drift-between-declared-and-actual-contracts)).

The answers drift apart. In 4 of the 9 configurations tested on `main`, different parts of the app disagree ([RFC §9, E2](rfc-ai-ml-v0.8.md#9-evidence-from-experiments)):

- With only an Anthropic key, the Enhance merchants button is missing, although the enhancer job would use Anthropic.
- With `OPENAI_MODEL=o4-mini`, or an OpenAI-compatible URL and no model, chat is offered and every chat turn fails.

Per-task models ([#4245](https://github.com/we-promise/sure/issues/4245)) have nowhere to live. Most contributions are written by coding agents that copy the nearest example, so each new feature adds another copy of the pattern ([02 B1](02-ai-architecture-review.md)).

Constraints:

- Public boundaries must not move without a decision: MCP and API v1, tool names and schemas, ENV names, job names and queues, stored data ([01 D5](01-ai-ml-workflow-map.md#d5-interface-register)).
- 342 open PRs compete for reviewers, so changes must be small and easy to revert.
- Sure ships a patch release every month. Breaking changes need a minor release, and the date of the next one (v0.8) is open.
- The [roadmap](https://sure.am/roadmap) puts "Reliability, performance, and technical debt" ahead of "First-class AI".

## Decision

1. **One router.** Every AI feature asks `Ai::Router.for(task, family:)`, which returns `Route(provider, model)` or `Unavailable(reason)`, or asks `Ai::Router.available?(task, family:)`. No other application code looks up an LLM provider or model. Evals are the exception: they build providers by name on purpose. Tasks: `chat`, `categorize`, `detect_merchants`, `enhance_merchants`, `extract_pdf`, `bill_setup`, `embed`.
2. **The router answers availability, not consent.** It says whether a provider can serve a task. A separate check decides whether this user's or account's data may be sent, and its policy gets its own ADR.
3. **Delegate first, then replace.** The first router delegates to today's resolution code, and call sites move over one PR at a time. Then the operations move behind it as task definitions (prompt, schema, mapper) over one structured-call primitive per transport. They go smallest first, from `bill_setup` to `chat`.
4. **Keep the current SDKs.** Transports stay on `ruby-openai` and `anthropic` through this work. A client library such as RubyLLM may later replace a transport, through its own ADR, if it passes the same cross-transport contract tests.
5. **No boundary changes.** This work changes no boundary interface in 01 D5. Each breaking change in [05](05-ai-breaking-change-option.md) needs its own ADR, migration and release note, and ships only in a minor release.
6. **Tests before code.** The shared LLM contract (`LLMInterfaceTest`, empty today), the agreement test from E2 and a lane test land before the code they protect. Once the migration is done, a cop forbids provider lookups outside `app/models/ai/`.

## Alternatives considered

### A. Fix each bug where it appears

For example, make the Enhance button call `preferred_llm_provider`.

- **Pros:** smallest change, and no new concept.
- **Cons:** the next provider or feature repeats the bug. One such fix already exists in six copies (the "Honors Setting.llm_provider (#2113)" comment). Per-task models get no home. Duplication keeps growing with every agent-written PR.

### B. The breaking-change option, all at once

[05](05-ai-breaking-change-option.md) BC1–BC11 in one coordinated series of releases.

- **Pros:** the cleanest end state. It removes the most code and concepts: AI locks, async rule actions, two chat paths, tuning in ENV.
- **Cons:** it bundles six maintainer decisions, reverses [#4310](https://github.com/we-promise/sure/issues/4310), and breaks operators' env files and MCP clients at the same time. Review load is heavy, and the risk of a half-finished migration is high.

### C. Adopt RubyLLM for every model call now

[04](04-rubyllm-thought-experiment.md)'s thought experiment.

- **Pros:** removes about 5,000 lines (an estimate) and most transport upkeep. Streaming on every provider. A model registry with prices.
- **Cons:** Sure still needs its own router and JSON-mode policy. It adds a large dependency with fast major versions and mostly one maintainer. The registry can go stale, and every failure policy needs its error classes remapped. [Chatwoot's migration](chatwoot-rubyllm-lessons-learned.md) shows that swapping the client does not, by itself, make an app multi-provider.

### D. A router first, adopted incrementally (chosen)

- **Pros:** each PR is small and revertible, and the disagreements above go away in the first PRs. Per-task models become a router setting. The 87 existing test stubs of the resolution methods keep working while call sites move. RubyLLM and each breaking option stay open.
- **Cons:** old and new code coexist during the migration. Contributors learn one new concept. It reaches the end state more slowly than B.

## Consequences

**Positive**

- One answer to "can AI do this here, and with which model?" In a spike (RFC E4), a 54-line delegating router plus six one-line call-site changes removed every disagreement in E2. The full unit suite passed: 13,163 runs, 0 failures, 0 errors. One existing test needed a one-line stub change.
- Per-task models ([#4245](https://github.com/we-promise/sure/issues/4245)) and model-aware defaults (U11) get one place to live.
- A new provider or operation touches one task file and its contract test, not a worker class per provider.
- Tests get one seam to stub.

**Negative**

- Some screens change, and each change needs a release note. The Enhance button appears on Anthropic-only installs. Chat and "Dig in with AI" are hidden when no provider accepts the configured model.
- Consent and availability have to be split early. Today `User#ai_enabled?` is `ai_enabled && ai_available?`, and `ai_available?` means "chat works", so chat also gates bill AI. That brings the consent policy question (05 BC10) forward.
- Until the cleanup phase, old and new resolution code coexist. The exit criterion: no provider lookups outside `app/models/ai/`, enforced by a cop.
- Tests that stub the old methods move to the router over time.

**Neutral**

- MCP, API v1, ENV names, job names and stored data are unchanged by this work. Any change to them waits for its own ADR and a minor release.
- RubyLLM stays an option for the transport layer.

## How we check it

- The E2 agreement test: every path gives the same answer for every configuration.
- `LLMInterfaceTest` runs one shared contract on every transport.
- Consent and availability are separate checks, each with its own test.
- A cop: no LLM provider lookup outside `app/models/ai/`, `lib/tasks/evals.rake` and `app/models/eval/`. Lookups are `Provider::Registry.get_provider(:openai | :anthropic | :jev)`, `preferred_llm_provider`, `llm_provider_order`, `Family#resolved_categorization_provider`, `Assistant::Provided#get_model_provider` and `Chat.default_model`. There are 23 call sites today; they start on an allow-list that must end empty.

These checks are rows 1–4 of the RFC's [finish line](rfc-ai-ml-v0.8.md#what-finished-means). This decision is carried out when those four rows hold.

## Follow-up decisions

Each gets its own ADR: suggestions and a resolver instead of AI locks (05 BC1, or the smaller 02 S7), the enrichment pipeline before rules (05 BC2, or 02 S4), chat history rebuilt from the database (05 BC4), tuning out of ENV (05 BC5), the MCP contract (05 BC6 and BC8), the consent policy (05 BC10), and a client library for a transport (04).
