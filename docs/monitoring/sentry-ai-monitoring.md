# Sentry AI Agent Monitoring

Sure emits [Sentry AI Agent Monitoring](https://docs.sentry.io/product/insights/ai/agents/) spans
around every LLM interaction, following the
[Sentry `gen_ai.*` span conventions](https://getsentry.github.io/sentry-conventions/attributes/gen_ai/).
This surfaces model usage, token consumption (and therefore cost), latency, tool
executions, and error rates in Sentry's **Insights → AI → Agents** views, fully
connected to the rest of the app's traces, errors, and logs.

Neither the Ruby nor the Flutter Sentry SDK ships an AI auto-integration
(those exist for JavaScript/Python only), so the instrumentation here is
manual, via span attributes.

## What is instrumented

### Rails backend (serves the web app / PWA)

All spans are emitted through `LlmInstrumentation`
(`app/models/llm_instrumentation.rb`), which is a safe no-op when Sentry is not
initialized:

| Span `op` | Where | What it covers |
|---|---|---|
| `gen_ai.invoke_agent` | `Assistant::Responder#respond` | A full assistant turn: LLM calls plus tool executions |
| `gen_ai.chat` | `Provider::Openai`, `Provider::Anthropic` chat paths | Each individual LLM call, with model + token usage |
| `gen_ai.execute_tool` | `Assistant::FunctionToolCaller#execute` | Each assistant function/tool call |
| `gen_ai.auto_categorize`, `gen_ai.auto_detect_merchants`, `gen_ai.enhance_provider_merchants`, `gen_ai.process_pdf`, `gen_ai.extract_bank_statement` | Provider one-shot operations | Background AI operations, with token usage attached via the provider `UsageRecorder` concerns |

Attributes always recorded: `gen_ai.system` (openai/anthropic),
`gen_ai.request.model`, `gen_ai.operation.name`, token usage
(`gen_ai.usage.input_tokens`, `.output_tokens`, `.total_tokens`, plus
`.input_tokens.cached`, `.input_tokens.cache_write`,
`.output_tokens.reasoning` where the provider reports them), and
`gen_ai.conversation.id` (the chat id) on chat spans so Sentry can group a
chat session. Token totals follow Sentry's cost model: cached/reasoning
counts are subsets of the totals (Anthropic's separately-reported cache
tokens are folded into the input total).

Agent runs are attributed to a pseudonymous user (`SHA256(user_id)` — the same
identifier used for Langfuse) in background jobs; web requests keep the richer
authenticated Sentry user set by `Authentication#set_sentry_user`.

### Flutter app (`mobile/`)

The mobile app never calls an LLM directly — the assistant runs server-side —
so it emits a `gen_ai.invoke_agent` transaction per assistant turn from
`ChatProvider`: the span opens when the user sends a message (or creates a
chat with an initial message) and closes when the assistant response finishes
streaming, errors, or times out. It carries `gen_ai.agent.name`
(`sure_assistant`, matching the backend) and a pseudonymous
`gen_ai.conversation.id` (hashed chat id — raw chat UUIDs are deliberately
redacted by the app's telemetry privacy layer). No message content is ever
attached on mobile.

Mobile Sentry is configured at build time via `--dart-define` (`SENTRY_DSN`,
`SENTRY_ENVIRONMENT`, `SENTRY_TRACES_SAMPLE_RATE`, ...) — see
`mobile/lib/services/telemetry_service.dart`.

## Configuration

Backend configuration lives in `config/initializers/sentry.rb`:

| Env var | Default | Purpose |
|---|---|---|
| `SENTRY_DSN` | unset (Sentry disabled) | Enables Sentry |
| `SENTRY_TRACES_SAMPLE_RATE` | `0.25` | Base sample rate for non-AI transactions |
| `SENTRY_SEND_DEFAULT_PII` | `false` | Opt-in capture of prompts, responses, and tool payloads on gen_ai spans |

### Sampling: AI traces are always kept

Agent runs are sampled as complete span trees — if the root transaction is
dropped, every child `gen_ai` span is lost with it. The initializer therefore
uses a `traces_sampler` that samples AI-related transactions
(`AssistantResponseJob`, `AutoCategorizeJob`, `AutoDetectMerchantsJob`,
`EnhanceProviderMerchantsJob`, `ProcessPdfJob`, and the chats/messages
controllers) at 100%, standalone `gen_ai.*` roots at 100%, and everything else
at the base rate.

### Privacy: prompt/response capture is opt-in

Prompts and model responses are user content and likely PII. By default only
model names, token counts, latency, and error status are recorded. Setting
`SENTRY_SEND_DEFAULT_PII=true` additionally attaches
`gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions`,
and `gen_ai.tool.call.arguments`/`.result` (each capped at 20k characters).

Before enabling it, confirm that your privacy policy permits capturing user
prompts and model responses, that captured data complies with applicable
regulations (GDPR, CCPA, ...), and that your Sentry data-retention settings are
appropriate. Note this flag also enables Sentry's general PII capture
(request IPs, etc.) per standard SDK behavior.

## Verification

1. Set `SENTRY_DSN` (and run with `RAILS_ENV=production`, the only enabled
   environment) or temporarily add your environment to
   `enabled_environments`.
2. Send an assistant chat message and let the response complete.
3. In Sentry, open **Explore → Traces** and filter for `span.op:gen_ai.chat` —
   spans appear as `chat {model}` with token counts, and the enclosing
   `invoke_agent sure_assistant` span shows the full turn including
   `execute_tool` children.
4. **Insights → AI → Agents** aggregates models, token usage/costs, and error
   rates.

Known limitation: Sentry's chat-style **Conversations** view reconstructs
messages from `gen_ai.input.messages`/`gen_ai.output.messages`, so it stays
empty unless `SENTRY_SEND_DEFAULT_PII=true`. The Ruby SDK also does not yet
support standalone gen-AI span streaming (`stream_gen_ai_spans`), so very
large payloads are subject to normal transaction size limits.
