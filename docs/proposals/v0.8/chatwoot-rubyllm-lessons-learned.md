# Lessons Learned: Chatwoot Captain Migration to RubyLLM

2026-10-24 · @josh-sanders

## Project summary

Chatwoot moved every AI feature of Captain off direct `ruby-openai` calls onto the [RubyLLM](https://rubyllm.com) gem in December 2025 (v4.9.0), then upgraded to RubyLLM 2.0 in October 2026 (v4.19.0). The migration met its goal of one provider-agnostic LLM layer, but Captain still runs OpenAI-only in practice and model-registry and endpoint issues remain open.

- **Scope:** reply-editor AI actions, Captain Copilot, the customer-facing assistant, FAQ generation, embeddings, audio transcription, and the Captain V2 agent runtime (via the `chatwoot/ai-agents` gem).
- **Goal:** replace hand-written OpenAI client code with one abstraction that could later support more providers, with Langfuse tracing on every call.
- **People:** Aakash Bakhle (aakashb95) led the migration and the 2.0 upgrade; Shivam Mishra (scmmishra) built the early prototype, `ai-agents` and dependency fixes; Sony Mathew contributed the LLM feature router and the CVE triage.
- **Phases:** an unmerged prototype (April 2025), indirect adoption through `ai-agents` (June–August 2025), the main migration (November–December 2025), hardening on 1.x (January–September 2026), and the 2.0 upgrade (September–October 2026).

## Timeline at a glance

The core migration took two weeks of merges (Dec 4–11, 2025); the 2.0 upgrade took 15 days from first commit to merge. Newest first.

| Date | Release | PR / commit | Milestone |
| --- | --- | --- | --- |
| 2026-10-13 | after v4.19.0 | [#16078](https://github.com/chatwoot/chatwoot/pull/16078) | OpenAI text inference moves to the Responses API |
| 2026-10-07 | v4.19.0 | [#15983](https://github.com/chatwoot/chatwoot/pull/15983) `f5bbc0484` | Chatwoot on `ruby_llm ~> 2.0.0`, `ai-agents ~> 0.13.0` |
| 2026-10-06 | v4.19.0 | [#16166](https://github.com/chatwoot/chatwoot/pull/16166) `05ace44a8` | `ai-agents` pinned to 0.12.x to block an early 2.0 pull-in |
| 2026-09-30 | — | [ai-agents#78](https://github.com/chatwoot/ai-agents/pull/78) | `ai-agents` gem moves to RubyLLM 2.0 |
| 2026-09-22 | — | `5ebb3c584` | 2.0 migration starts on `codex/rubyllm-2-chatwoot` |
| 2026-09-16 | v4.18.0 | [#15847](https://github.com/chatwoot/chatwoot/pull/15847) | CI audit exception for RubyLLM CVE-2026-67991 |
| 2026-06-25 | — | [#14839](https://github.com/chatwoot/chatwoot/pull/14839)–#14843 | Per-feature LLM model router |
| 2026-05-08 | v4.14.0 | [#14387](https://github.com/chatwoot/chatwoot/pull/14387) | Bump to `ruby_llm >= 1.14.1` |
| 2026-04-16 | v4.13.0 | [#14067](https://github.com/chatwoot/chatwoot/pull/14067) | Model registry committed to the repo |
| 2025-12-11 | v4.9.0 | [#12994](https://github.com/chatwoot/chatwoot/pull/12994) | FAQ, embeddings, transcription moved to RubyLLM |
| 2025-12-05 | v4.9.0 | [#13011](https://github.com/chatwoot/chatwoot/pull/13011) | `ruby_llm` / `ai-agents` version conflict fixed |
| 2025-12-04 | v4.9.0 | [#12981](https://github.com/chatwoot/chatwoot/pull/12981) | Copilot and assistant moved to RubyLLM |
| 2025-12-04 | v4.9.0 | [#12961](https://github.com/chatwoot/chatwoot/pull/12961) | Editor AI moved; `ruby_llm` enters the Gemfile |
| 2025-11-22 | — | [#12905](https://github.com/chatwoot/chatwoot/pull/12905), [#12949](https://github.com/chatwoot/chatwoot/pull/12949) | Langfuse tracing and Captain instrumentation land first |
| 2025-08-14 | v4.5.0 | [#11944](https://github.com/chatwoot/chatwoot/pull/11944) | Captain V2 agents on `ai-agents` (RubyLLM underneath) |
| 2025-04-04 | — | `0d0df0eea`…`45afde970` | Prototype on `feat/ruby-llm`, never merged |

## What went well

The team sequenced the work well: observability first, then small slices, then a guarded major-version upgrade.

1. **Instrumentation before migration.** Langfuse/OTEL tracing (#12905) and Captain instrumentation (#12949) merged a week before the first migration PR, so every migrated path could be checked against traces (#12961 was verified in Langfuse).
2. **Sliced by feature area.** Editor (#12961), then Copilot and assistant (#12981), then legacy jobs (#12994), with explicit merge order stated in the PR body. Each slice was reviewable and revertible.
3. **Breaking changes labelled.** #12961 and #12981 were marked as breaking and scoped to OpenAI models only, which set honest expectations.
4. **Guarded 2.0 rollout.** #16166 pinned `ai-agents` to 0.12.x the day before #15983 merged, so a routine `bundle update` could not pull RubyLLM 2 in early. The library (ai-agents#78) was migrated and merged before the app.
5. **Evidence-based security triage.** #15847 documented why CVE-2026-67991 did not apply on Ruby 3.4.4, reproduced the behaviour on 3.1.0 vs 3.4.4, and stated a removal condition.
6. **Shipped in releases with notes.** v4.9.0 release notes (Discussion #13117) told self-hosters the migration was happening.

## What didn't go well

Six problems recurred after the migration; four still have open issues as of this review.

| # | Problem | Evidence | Status |
| --- | --- | --- | --- |
| P1 | New models rejected by RubyLLM's static registry | Dec 2025 gpt-5.1/5.2 fix reverted same day (`d75e1393d`/`5b5e6a852`); #13568 closed; #14067; [#16114](https://github.com/chatwoot/chatwoot/issues/16114) (gpt-6) | Open |
| P2 | Dependency conflict between direct `ruby_llm` and `ai-agents` | #13011 one day after #12961 lowered the floor from 1.9.1 to 1.8.2; #16166 pin before 2.0 | Resolved per upgrade, recurs each major |
| P3 | Custom endpoint `/v1` handled differently in three code paths | [#14789](https://github.com/chatwoot/chatwoot/issues/14789), [#15902](https://github.com/chatwoot/chatwoot/issues/15902), PR #14790 unmerged | Open |
| P4 | Lost per-step timing in traces | #12981 note: RubyLLM callbacks fire after the response (ruby_llm issue 414) | Accepted trade-off |
| P5 | Multi-provider promise not delivered | #13188, [#13543](https://github.com/chatwoot/chatwoot/issues/13543); #14562 tested Anthropic, Azure, OpenRouter but closed unmerged | Open |
| P6 | Unbounded agent/tool loops and silent timeouts | [#16251](https://github.com/chatwoot/chatwoot/issues/16251), #15901, [#14564](https://github.com/chatwoot/chatwoot/issues/14564) | Open |

Two smaller items: the April 2025 prototype (`feat/ruby-llm`) was abandoned and the work redone eight months later, and #15983 merged with its own note that a live provider smoke check "has not been confirmed in production."

## Root causes

Most problems trace back to one decision: the migration swapped the client library but kept OpenAI-shaped assumptions around it.

- **P1 Registry.** RubyLLM resolves model ids against a bundled catalog. Chatwoot calls `RubyLLM.chat(model:)` without a provider or `assume_model_exists` (#16114), so any model newer than the catalog fails. The fix (#14067) moved the catalog into the repo, which still needs a manual refresh per model release.
- **P2 Dependencies.** `ruby_llm` had two owners: the app's Gemfile and the `ai-agents` gemspec, maintained by the same team but released separately. Version floors were set independently, so they collided.
- **P3 Endpoints.** The custom endpoint setting is read and normalised in at least three places (`config/initializers/ai_agents.rb`, `lib/captain/base_task_service.rb`, `Llm::Config`), with no shared helper or test of the combined behaviour.
- **P4 Tracing.** The abstraction hides per-step events; app-level instrumentation can only see the finished call.
- **P5 Providers.** Each slice was scoped and tested against OpenAI only. Provider selection, credentials and model capability checks (image input, tool calls) were never designed as part of the migration, so the self-hosted provider PR (#14562) arrived as a large separate change.
- **P6 Loops.** The agent runtime has no hard cap on tool-call rounds or a fallback handoff; the migration did not add one.
- **Prototype.** No public PR, issue or decision record explains why the April 2025 branch stopped, and none of its commits reached `develop`.

## Lessons learned

These apply to any migration onto an LLM abstraction library, not just this one.

1. **An abstraction library does not make you multi-provider.** Provider choice, credentials and capability checks are product features; design them in or state they are out of scope.
2. **Treat the model catalog as live data.** A static registry goes stale with every model release. Plan how unknown models are handled on day one.
3. **Give each shared dependency a single owner.** When an internal gem and the app both depend on the same library, let the gem own the constraint and pin the gem.
4. **Normalise config in one place.** One helper for endpoint URLs, with tests for bare host, `/v1` and proxy prefixes, would have prevented P3.
5. **Instrument first, migrate second.** It worked here; keep doing it, and check up front what the new library hides.
6. **Pin before a major upgrade.** Constrain transitive versions first, migrate the library, then the app.
7. **Bound every agent loop.** Cap tool-call rounds and time per run, and hand off to a human when the cap is hit.
8. **Record why work stops.** A short note on an abandoned branch saves the next attempt from starting over.

## Recommendations and actions

Three actions close the open user-facing failures; the rest reduce the cost of the next upgrade. Owners are left for the team to assign. Status reflects linked PRs as of this review.

| Action | Fixes | Priority | Status | Related |
| --- | --- | --- | --- | --- |
| Handle unknown models: refresh `config/llm_models.json` on a schedule and fall back to `assume_model_exists` with the configured provider | P1 | High | Not started | #16114 |
| Cap tool-call rounds and run time in Copilot and Captain V2, with handoff on cap | P6 | High | In progress | #16252, #16035 |
| One endpoint-normalisation helper used by all three code paths, with tests | P3 | High | In progress | #14790, #15902 |
| Decide and publish the multi-provider plan (revive #14562 or state OpenAI-only) | P5 | Medium | Not started | #13543 |
| Let `ai-agents` own the `ruby_llm` constraint; app pins only `ai-agents` | P2 | Medium | Not started | #16166 |
| Live smoke test per provider in CI before LLM dependency bumps merge | P1, P5 | Medium | Not started | #15983 |
| Push for step-level hooks upstream or trace inside `ai-agents` | P4 | Low | Not started | ruby_llm issue 414 |

## Metrics

From the first direct `ruby_llm` dependency (Dec 2025) to the 2.0 upgrade took 10 months and seven later Gemfile constraint changes to `ruby_llm` or `ai-agents`.

| Measure | Value |
| --- | --- |
| Prototype to first merge | 8 months (2025-04-04 to 2025-12-04) |
| Core migration PRs merged | 3 in 8 days (#12961, #12981 on Dec 4; #12994 on Dec 11) |
| Follow-up fixes within a week | 2 (#13005, #13011) |
| 2.0 upgrade, first commit to merge | 15 days (2026-09-22 to 2026-10-07) |
| Open issues tied to RubyLLM paths | 7 (#14564, #14789, #15901, #15902, #16114, #16251, #13543) |

**`ruby_llm` constraint in the Gemfile**

| Date | PR | `ruby_llm` | `ai-agents` |
| --- | --- | --- | --- |
| 2026-10-07 | #15983 | `~> 2.0.0` | `~> 0.13.0` |
| 2026-10-06 | #16166 | `>= 1.14.1` | `~> 0.12.0` |
| 2026-06-29 | #14878 | `>= 1.14.1` | `>= 0.12.0` |
| 2026-05-08 | #14387 | `>= 1.14.1` | `>= 0.10.0` |
| 2026-02-24 | #13581 | `>= 1.8.2` | `>= 0.9.1` |
| 2025-12-05 | #13011 | `>= 1.8.2` | `>= 0.7.0` |
| 2025-12-04 | #12961 | `>= 1.9.1` | `>= 0.4.3` |
| 2025-08-14 | #11944 | via `ai-agents` | `>= 0.4.3` |

## Sources

Built from the public record only; no interviews with the Chatwoot team, so motives are inferred from PR text.

- [chatwoot/chatwoot](https://github.com/chatwoot/chatwoot) git history: commit messages matching "ruby llm" and Gemfile changes to `ruby_llm` / `ai-agents`, all branches.
- PRs and issues found by GitHub search for rubyllm, ruby_llm, ruby-llm and RubyLLM.
- [Discussion #13117](https://github.com/chatwoot/chatwoot/discussions/13117) (v4.9.0 release notes), the only discussion mentioning RubyLLM.
- [chatwoot/ai-agents](https://github.com/chatwoot/ai-agents) gemspec history and [PR #78](https://github.com/chatwoot/ai-agents/pull/78).
- Release tags (v4.5.0 to v4.19.0) used to place each change.
