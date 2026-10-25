# Experiments behind the v0.8 AI RFC

Four checks run on `main` @ `445b668d2` (2026-10-25) to test the claims in [the RFC](../rfc-ai-ml-v0.8.md) and the decision in [ADR-0001](../adr-0001-one-ai-router.md). They used the project's normal test setup (PostgreSQL 16 with pgvector, Valkey, Ruby 3.4.9, `RAILS_ENV=test`). **The code is throwaway, not for merge.**

| ID | Question | Method |
|---|---|---|
| E1 | Do the documents' numbers still hold? | `grep` recount on `main` |
| E2 | Do the places that decide "which AI applies?" agree? | One integration test sets nine configurations and asks every path. The Enhance button is measured by rendering the Merchants page. |
| E3 | Does the declared provider interface match the providers? | Ruby reflection on `Provider::LlmConcept` and the implementations |
| E4 | How big and how safe is a first router step? | A delegating `Ai::Router`, six call sites moved onto it, then E2 and the full unit suite |

## Reproduce

```sh
git checkout 445b668d2
# E2 and E3 on main: apply only the experiment test.
git apply --include='test/rfc_experiments/*' docs/proposals/v0.8/experiments/router-spike.patch
RFC_OUT=/tmp bin/rails test test/rfc_experiments/ai_paths_agreement_test.rb
# E4: apply the rest (router, call sites, one test update), then run E2 and the suite again.
git apply --exclude='test/rfc_experiments/*' docs/proposals/v0.8/experiments/router-spike.patch
RFC_OUT=/tmp bin/rails test test/rfc_experiments/ai_paths_agreement_test.rb
bin/rails test
```

Adjust the patch path to wherever this folder sits. E2 renders a page, so it needs `app/assets/builds/tailwind.css` (`bin/rails tailwindcss:build`). The test writes `e2-agreement.md` and `e3-concept-drift.md` to `RFC_OUT`.

## E1. Recount

| Claim | Source | Result on `445b668d2` |
|---|---|---|
| `parse_json_flexibly` / `strip_thinking_tags` / `extract_http_status_code` defined 5 / 4 / 4 times | 02 §1 | 5 / 4 / 4 |
| "Honors Setting.llm_provider (#2113)" comment copied 6 times | 02 §1 | 6 |
| The Enhance button checks OpenAI only | 01 D4 #1 | Yes: `family_merchants_controller.rb:32` (the only other `get_provider(:openai)` is in `lib/tasks/evals.rake`) |
| `LLMInterfaceTest` declares no tests | 01 D5.7 | It holds one private VCR helper |
| `vector_store_chunks` is not in `db/schema.rb` | 01 D5.6 #6 | 0 matches |
| The AI-lane test lists its jobs by hand | 01 D5.7 I23 | `AI_JOBS` lists 5 jobs |
| 41 ENV reads in the AI settings views | consistency check | 41 in the six AI partials, 78 across all `settings/hostings` views |
| Commits since the documents' reference commit `2250ba801` | README | 5, none in AI/ML code |

## E2. Do the paths agree?

Each column is one configuration. Every other AI variable is cleared, and the app runs in self-hosted mode.

- **C1** nothing configured
- **C2** `OPENAI_ACCESS_TOKEN=sk-test`
- **C3** `ANTHROPIC_API_KEY=sk-ant-test` (Anthropic only, `LLM_PROVIDER` unset)
- **C4** `ANTHROPIC_API_KEY=sk-ant-test LLM_PROVIDER=anthropic`
- **C5** `OPENAI_ACCESS_TOKEN=ollama OPENAI_URI_BASE=http://ollama:11434/v1 OPENAI_MODEL=qwen3:8b`
- **C6** `OPENAI_ACCESS_TOKEN=ollama OPENAI_URI_BASE=http://ollama:11434/v1` (model left blank)
- **C7** `OPENAI_ACCESS_TOKEN=sk-test ANTHROPIC_API_KEY=sk-ant-test LLM_PROVIDER=anthropic`
- **C8** `OPENAI_ACCESS_TOKEN=sk-test OPENAI_MODEL=o4-mini`
- **C9** `JEV_API_KEY=jev-test CATEGORIZATION_PROVIDER=jev` (no LLM)

### On `main`

| Question | Code | C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 |
|---|---|---|---|---|---|---|---|---|---|---|
| batch / PDF / bills provider | `Provider::Registry.preferred_llm_provider` | – | Openai | Anthropic | Anthropic | Openai | – | Anthropic | Openai | – |
| categorization provider | `Family#resolved_categorization_provider` | – | Openai | Anthropic | Anthropic | Openai | – | Anthropic | Openai | Jev |
| chat model stamped on a message | `Chat.default_model` | `gpt-4.1` | `gpt-4.1` | `claude-sonnet-4-6` | `claude-sonnet-4-6` | `qwen3:8b` | `gpt-4.1` | `claude-sonnet-4-6` | `o4-mini` | `gpt-4.1` |
| chat provider for that model | `Assistant::Provided#get_model_provider` | – | Openai | Anthropic | Anthropic | Openai | – | Anthropic | – | – |
| chat entry point shown | `User#ai_available?` | no | yes | yes | yes | yes | **yes** | yes | **yes** | no |
| bill smart-fill shown | `bills_one_shot_ai_available?` | no | yes | yes | yes | yes | no | yes | yes | no |
| "Dig in with AI" shown | `insight_dig_in_available?` | no | yes | yes | yes | yes | no | yes | **yes** | no |
| AI categorize rule action offered | `TransactionResource#offered?` | no | yes | yes | yes | yes | no | yes | yes | yes |
| AI merchant rule action offered | `TransactionResource#offered?` | no | yes | yes | yes | yes | no | yes | yes | no |
| Enhance merchants button rendered | GET `/family_merchants` | no | yes | **no** | **no** | yes | no | yes | yes | no |
| vector store adapter | `VectorStore::Registry.adapter_name` | – | openai | – | pgvector | openai | openai | pgvector | openai | – |

Disagreements:

- **C3, C4:** the Enhance button is not rendered, but the enhancer job would use Anthropic.
- **C6:** chat is shown, but no provider accepts `gpt-4.1` (the registry refuses a custom URL without a model), so every chat turn fails.
- **C8:** chat and "Dig in" are shown, but the native allow-list (`gpt-4 gpt-5 gpt-6 o1 o3`) rejects `o4-mini`, so every chat turn fails. Categorization, merchant detection and bill smart-fill don't check the allow-list, so they go ahead with `o4-mini`.

Also visible, though not counted as disagreements:

- **Vector store:** the default follows the `LLM_PROVIDER` setting, not the configured credentials. The same Anthropic key gives no store in C3 and pgvector in C4. In C7, switching `LLM_PROVIDER` to `anthropic` moves the store from OpenAI to pgvector. *Inferred, not run:* documents uploaded before the switch would no longer be found.
- **C5 without the AI compose file:** the default adapter is `openai`, built with `OPENAI_URI_BASE`, so it would call OpenAI's vector-store API on the Ollama URL. *Inferred, not run.* `compose.example.ai.yml` avoids this by setting `VECTOR_STORE_PROVIDER=pgvector`.

### With the router spike (E4)

| Question | C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 |
|---|---|---|---|---|---|---|---|---|---|
| chat entry point shown | no | yes | yes | yes | yes | **no** | yes | **no** | no |
| bill smart-fill shown | no | yes | yes | yes | yes | no | yes | **no** | no |
| "Dig in with AI" shown | no | yes | yes | yes | yes | no | yes | **no** | no |
| AI categorize rule action offered | no | yes | yes | yes | yes | no | yes | yes | yes |
| AI merchant rule action offered | no | yes | yes | yes | yes | no | yes | yes | no |
| Enhance merchants button rendered | no | yes | **yes** | **yes** | yes | no | yes | yes | no |

The other rows are unchanged. **Disagreements: none.** Bill smart-fill in C8 is the one unwanted change (see E4).

## E3. Declared vs actual provider interface

| Method | `LlmConcept` declares | OpenAI | Anthropic | Jev |
|---|---|---|---|---|
| `auto_categorize` | `transactions` | `transactions:, user_categories:, model:, family:, json_mode:` (all optional) | same as OpenAI | same as OpenAI |
| `auto_detect_merchants` | `transactions` | `transactions:, user_merchants:, model:, family:, json_mode:` | same | – |
| `enhance_provider_merchants` | `merchants` | `merchants:, model:, family:, json_mode:` | same | – |
| `suggest_bill_setup` | `charges:` required | `charges:` optional | `charges:` optional | – |
| `supports_pdf_processing?` | no arguments | `model:` | `model:` | – |
| `process_pdf` | `pdf_content:, family:` | adds `model:`, `json_mode:` | adds `model:` | – |
| `extract_bank_statement` | **not declared** | `pdf_content:, model:, family:, json_mode:` | `pdf_content:, model:, family:` | – |
| `chat_response` | 12 parameters | adds `family:` | adds `family:` | – |

Jev includes only `Provider::ClassificationConcept`, yet implements the LLM-shaped keyword `auto_categorize` that `Family::AutoCategorizer` calls. This confirms 01 D5.6 drift 1–3.

## E4. A first router step

The spike (in `router-spike.patch`):

| File | Change |
|---|---|
| `app/models/ai/router.rb` | New, 54 lines. `for(task, family:)` returns `Route(provider, model)` or `Unavailable(reason)`, and `available?` wraps it. It delegates to today's code: the registry's provider order for LLM tasks, `Family#resolved_categorization_provider` for categorization, and for chat the first provider that accepts `Chat.default_model`. |
| `family_merchants_controller.rb`, `user.rb`, `bills_helper.rb`, `insights_helper.rb`, `rule/registry/transaction_resource.rb` | Six lines: each availability check asks the router |
| `test/controllers/insights_controller_test.rb` | One line: stub the router instead of `Provider::Registry.preferred_llm_provider` |

Results:

| Run | Runs | Failures | Errors | Skips |
|---|---|---|---|---|
| Full unit suite on `main` (plus the experiment test) | 13,163 | 0 | 0 | 36 |
| Full unit suite with the spike | 13,163 | 0 | 0 | 36 |
| The 33 test files that touch the moved code, before the one-line test update | 802 | 1 | 0 | 1 |

What the spike showed:

1. **Delegating first keeps existing tests working.** The suite stubs today's resolution methods 87 times: `preferred_llm_provider` 43 times in 14 files, `get_provider` 37 times in 12 files, `resolved_categorization_provider` 7 times in 2 files. Because the router calls those methods, the stubs still apply. Only the "Dig in" test failed, because "Dig in" now asks whether chat can answer, which is the intended fix.
2. **Consent and availability are tangled.** `User#ai_enabled?` is `ai_enabled && ai_available?`, and `ai_available?` means "chat works". After the spike made chat availability honest, bill smart-fill disappeared in C8, although the bill suggester works there. The real change must check the consent flag and the task's availability separately.
3. **A workflow was missing from 01.** `Bills::AiReviewsController` ([#3202](https://github.com/we-promise/sure/issues/3202)) starts a chat from the bills page with a fixed review prompt. It is gated by `bills_one_shot_ai_available?`, which checks the batch provider, not chat. So in C8 its button is shown and the chat it opens fails. It is now [W24](../01-ai-ml-workflow-map.md#w24-bills-ai-review) in 01, and it should be gated on the `chat` task.
4. **A spike bug worth remembering.** The first version read the provider's model during availability checks. Tests that stub the provider with a plain object then raised `NoMethodError`. Availability checks should not touch model configuration.
