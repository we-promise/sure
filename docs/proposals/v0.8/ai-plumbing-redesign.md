# Sure — AI plumbing redesign

Status: proposal · Target: `we-promise/sure` (`origin/main` @ `a6767e931`) · 2026-10-28

Audience: the Sure dev team. This document describes the structure the AI layer is moving to and
the pull requests that get it there (section 19).

## 1. What exists today (evidence)

Each AI capability brought its own provider resolution, prompt, output parsing, usage
recording and failure policy. The duplication is real and has already drifted.

| Concern | Where it lives today | Copies |
|---|---|---|
| Provider resolution | `Provider::Registry.preferred_llm_provider`, `llm_provider_order`, `Assistant::Provided#get_model_provider`, `Family#resolved_categorization_provider` / `#shadow_categorization_provider`, `Chat.default_model`, `Eval::ProviderFactory`, `AiHealth#load_llm_status` | 7, with 23 call sites and 87 test stubs |
| "Is AI available?" | `User#ai_available?`/`#ai_enabled?`, `BillsHelper#bills_one_shot_ai_available?`, `FamilyMerchantsController` (`get_provider(:openai).present?`), `Rule::Registry::TransactionResource#auto_*_enabled?`, `PdfImport#process_with_ai`, `Api::V1::BaseController#require_ai_enabled` | 7+ |
| Structured-output workers | `Provider::{Openai,Anthropic}::{AutoCategorizer, AutoMerchantDetector, ProviderMerchantEnhancer, BillSetupSuggester, PdfProcessor, BankStatementExtractor}` | 12 classes, ~3,200 lines |
| Usage + cost | `Provider::Openai::Concerns::UsageRecorder`, `Provider::Anthropic::Concerns::UsageRecorder`, `Provider::Openai#record_llm_usage`, `Provider::Anthropic#record_llm_usage` | 4 |
| Langfuse | `create_langfuse_trace` / `log_langfuse_generation` / `upsert_langfuse_trace` in both providers, `span&.end` in every worker | 2 + 12 |
| JSON recovery (`<think>` tags, fenced JSON) | `parse_json_flexibly` / `strip_thinking_tags` per OpenAI worker | ~5 |
| AI settings | 54 AI ENV variables. "ENV > Setting > default" is re-implemented in 68 methods and 41 view reads. The web and worker processes resolve them separately, so a value the UI shows can differ from the one jobs use. | many |
| LLM calls on web threads | smart-fill and smart-configure, non-PDF embedding in `ImportsController`, MCP `import_bank_statement` and `search_family_files`, health probes | 5 paths |
| Health probes | `AiHealth::Probe` builds its own `OpenAI::Client` / `Anthropic::Client` | separate code path from production calls |

Since #4239, `Insight::BodyWriter` is a deterministic i18n template, so insights make no LLM call.
The only AI in insights is "Dig in with AI", which opens a chat.

Drift bugs this has already produced (verified in the code):

1. **`FamilyMerchantsController#index`** decides `@llm_available` from `get_provider(:openai)` only,
   so on an Anthropic-only install the merchant enhancement button is hidden even though
   `ProviderMerchant::Enhancer` routes to Anthropic.
2. **Usage on failure is inconsistent**: `Provider::Anthropic::BillSetupSuggester` calls
   `record_usage_error`; `Provider::Openai::BillSetupSuggester` does not. Failed OpenAI bill
   suggestions don't appear on the LLM usage page.
3. **Failure policy is inconsistent**: `Family::AutoCategorizer` raises `Error`,
   `Family::AutoMerchantDetector` raises a bare `RuntimeError` when unconfigured and returns `0`
   on provider failure, and `ProviderMerchant::Enhancer` skips the failed batch without logging it.
4. **Consent is checked per feature**: bills check `Current.user.ai_enabled?`, while PDF import,
   merchant enhancement and rule-driven categorization don't check consent at all.
5. **Embeddings ignore Settings**: `VectorStore.embedding_uri_base` falls back to
   `ENV["OPENAI_URI_BASE"]` but not to `Setting.openai_uri_base`, unlike every other AI setting.
6. **Health probes test a different code path**: `AiHealth::Probe` constructs clients itself, so a
   probe can pass while a production call fails (for example on extra headers, request timeout
   or session headers that only `Provider::Openai#initialize` applies).
7. **Interactive calls aren't prioritised**: with `RAILS_AI_MAX_THREADS=1`, a multi-minute batch
   job that's already running blocks chat (chat waited 56–104 s on one instance).
   `Bills::SmartConfigurationsController#show` calls the LLM inside the web request and competes
   for the same local model.
8. **Shadow runs are a categorization-only special case**: `Family#shadow_categorization_provider`
   and `Family::AutoCategorizer#run_shadow` call the other provider synchronously inside the
   primary job, which doubles the time the AI thread is held, and record it under the same
   operation, so its cost can't be told apart.

Other facts the design depends on:

- **Anthropic skips the proxy**: the `anthropic` SDK uses `Net::HTTP`, which reads only
  `HTTP_PROXY`, even for HTTPS. Pipelock setups that set only `HTTPS_PROXY` send Anthropic calls
  direct.
- **Model acceptance**: native OpenAI chat accepts only some model prefixes. With `o4-mini`, chat
  is offered and every turn fails, while categorization works.
- **Jev** sends one request per transaction on an 8-thread pool inside the Sidekiq thread.
- **The AI-cache reset**: changing `openai_model` in the UI clears every family's AI cache. ENV,
  Anthropic and `LLM_PROVIDER` changes don't.

## 2. Who the AI layer serves

The router and the sequencer exist to make AI work for four kinds of people. Every design choice
below traces back to one of these needs.

**Family admin**

- F1. Turn AI on or off, per feature, for the family, and turn it off for a member.
- F2. Know where the family's data goes, local or cloud, and keep it local if they choose.
- F3. Have categories and merchants filled in automatically, and fix them easily.
- F4. Be told when AI isn't working, rather than finding broken features.
- F5. Choose the chat mode, built-in or external, or turn chat off.

**Home lab with a local LLM**

- H1. Choose per feature which model runs it, local or cloud: a small model for background work,
  a big one for chat, an embedding model for documents, possibly on two servers.
- H2. Never overload the local hardware (GPU or CPU) shared by their model servers, and have chat
  go first.
- H3. Keep config as code, so it can be rebuilt.
- H4. See whether each model is up, what it can do and how fast it is.
- H5. Allow slow models long timeouts.

**Multi-tenant admin**

- M1. One set of keys and endpoints for many families, which families can't change.
- M2. Fairness: one family's 10,000-row import doesn't stall another family's chat.
- M3. Stay within provider rate limits, and fail over when a provider is down.
- M4. See usage and cost per family.
- M5. Keep a record of what data each feature sends, with consent recorded.
- M6. Upgrades that come with migrations and release notes.
- M7. Let a family bring its own key for a cloud endpoint, so its usage is billed to its own
  account and one family's quota or key problem doesn't affect another (#3037).

**User**

- U1. Chat that streams quickly and isn't stuck behind background work.
- U2. Opt out of AI personally, chat included, without affecting other members.
- U3. Features that work, or say clearly that they're unavailable. Never a stack trace.
- U4. Know when AI made a change, and undo it.

| Need | Served by |
|---|---|
| F1, U2, M5 | Two-level consent with a data manifest per feature, and a member switch only an admin can turn off (section 6; the family level in PR 6) |
| F2 | The family's allowed endpoints; each endpoint is marked local or cloud (sections 4, 6; PR 8) |
| F3, U4 | Domain provenance (`source: "ai"`) and enrichment locks, unchanged |
| F4, U3 | `Ai::Availability` reasons, `Ai::AffordanceComponent` and the "AI unavailable" notice (sections 5.4, 16) |
| F5 | The family's chat mode, and chat's switch on the AI features page (section 6) |
| H1 | Endpoints with several models, each marked local or cloud, and one ordered model list per feature (sections 4, 5) |
| H2, U1 | The sequencer: one call at a time per local host, and lane priority (section 11) |
| H3, M1 | The `AI_CONFIG` file, loaded into the database (section 4) |
| H4 | Probe jobs per model, and the health page (section 13) |
| H5 | `timeout_seconds` per endpoint |
| M2 | Small batches that re-enqueue at the back of the queue, so families take turns (section 11) |
| M3 | No slot on cloud endpoints, 429 backoff, failover and escalation in the model list |
| M4 | `llm_usages` per family and feature, with a correlation id (section 10) |
| M6 | Section 18 |
| M7 | `AiEndpointCredential`: a family's own key for one cloud endpoint, used for that family's calls, with down marks per key (sections 4.2, 5.4) |

## 3. Target shape

One namespace, `Ai::`, under `app/models/ai/`, plus four ActiveRecord models for configuration.
This follows conventional Rails structure: rich models and POROs in `app/models`, concerns for
shared behaviour, thin RESTful controllers, ActiveJob for slow work, ActiveSupport::Notifications
for cross-cutting instrumentation.

```
app/models/ai.rb                         # Ai.available?, Ai.availability — the façade
app/models/ai_endpoint.rb                # AR: one connection (protocol, URL, encrypted key, flags)
app/models/ai_model.rb                   # AR: a model on an endpoint, with its capabilities
app/models/ai_route.rb                   # AR: one entry in a feature's ordered model list, with optional overrides
app/models/ai_endpoint_credential.rb     # AR: a family's own key for one cloud endpoint
app/models/family/ai_settings.rb         # concern: every family AI setting, kept out of family.rb
app/models/ai/
  config.rb                              # per-process cache of the three tables + instance values
  config_file.rb                         # loads AI_CONFIG into the tables at boot (AI workers only)
  legacy_env_config.rb                   # deprecated: reads the old AI ENV as a generated config file
  preset.rb                              # reads config/ai/presets/*.yml
  consent.rb                             # family consent per row, the member switch, the user switch
  router.rb                              # THE resolution path
  routes.rb                              # THE routing table (feature → lane, needs, consent, data sent)
  plan.rb                                # Data: feature, lane, ordered candidate routes
  route.rb                               # Data: endpoint, model, transport, json_mode, prompt, key and whose key
  availability.rb                        # Data: available? + reason (for no-AI UI)
  result.rb                              # Data: success/failure wrapper
  error.rb                               # error taxonomy
  sequencer.rb                           # one slot per local host, lane priority
  prompt.rb                              # file-backed prompts + family overrides
  schema.rb                              # JSON-Schema → coercion/validation
  generation.rb                          # base class for structured-output features
  owner.rb                               # the domain side of a feature: rebuild, generate, apply (section 8.1)
  owners.rb                              # feature key → owner class registry
  batch.rb                               # slices items by batch_size and tokens (was Provider::Openai::BatchSlicer)
  judgement.rb                           # base class for typed-decision features (Jev)
  conversation.rb                        # chat-with-tools primitive
  comparison.rb                          # AR: primary vs shadow output, any feature
  transport/                             # hand-written, or a thin adapter over RubyLLM (section 19)
    base.rb
    compatible.rb                        # chat completions or Responses API; embeddings; vector stores
    anthropic.rb                         # Messages API, forced tool_use for structured output
    jev.rb                               # judge only
    http.rb                              # one place clients are built: timeout, proxy, headers
  generations/                           # ONE small declarative file per feature
    categorize_transactions.rb
    detect_merchants.rb
    enhance_merchants.rb
    read_pdf.rb
    extract_bank_statement.rb
    suggest_bill_setup.rb
  judgements/
    categorize_transaction.rb
  instrumentation/
    usage_subscriber.rb                  # → LlmUsage
    langfuse_subscriber.rb               # → Langfuse
    debug_log_subscriber.rb              # → DebugLogEntry
    comparison_subscriber.rb             # → Ai::Comparison (shadow runs)
config/ai/presets/                       # one YAML file per provider
  openai.yml  anthropic.yml  gemini.yml  openrouter.yml  llama_cpp.yml  ollama.yml  jev.yml  jev_local.yml
config/ai.example.yml                    # documented example of the AI_CONFIG file
app/prompts/                             # every prompt, one home; <name>.<locale>.md for translations
app/jobs/ai/generation_job.rb            # generic, lane-aware, batch-yielding, cancellable
app/jobs/ai/shadow_job.rb                # a shadow run, on ai_background
app/jobs/ai/probe_job.rb                 # health probe for one model
app/jobs/ai/tool_job.rb                  # runs an AI-dependent MCP tool in the ai capsule
app/models/recurring_transaction/suggestion.rb   # AR: one smart-fill or smart-configure request, cancellable
app/mailers/ai_consent_mailer.rb         # tells members when a background feature is turned on (PR 6)
test/support/ai_test_helper.rb           # with_ai_routes, without_ai, stub_ai, with_ai_capsule
app/controllers/concerns/ai_feature_guard.rb
app/controllers/settings/ai/*.rb
lib/rubocop/cop/sure/*.rb
```

`Provider::Jev` and the structured-output parts of `Provider::Openai` and `Provider::Anthropic`
are removed in PR 2, and the rest of those two in PR 3 (section 19). `Provider::Registry` keeps its non-AI concepts: exchange rates, securities,
property valuations and Plaid.

### Four families of intelligent behaviour

| Family | Primitive | Base class | Transports | Engines outside the plumbing |
|---|---|---|---|---|
| 1. Generation | `transport.generate(request)` → structured JSON; `transport.converse(request, &stream)` → chat with tools | `Ai::Generation`, `Ai::Conversation` | `compatible`, `anthropic` | — |
| 2. Judgement | `transport.judge(state:, questions:)` → `DecisionSet` | `Ai::Judgement` | `jev` | — |
| 3. Embeddings | `transport.embed(texts)`, or an OpenAI vector store | used by `VectorStore` | `compatible` | pgvector, Qdrant |
| 4. Ruby ML / heuristics | — | **not part of the AI layer** | — | Bayes, TF-IDF, transfer SQL, recurring clustering, insight generators |

Family 4 doesn't go through the AI path. It has no transport, consent, cost, trace, sequencer slot
or prompt. These engines stay ordinary domain models, and the router never names them. The
classifier settings page (`Settings::ClassifiersController`, #4310) stays outside `Settings::Ai`.

**The domain model owns the fallback order. The AI layer only answers "is an external model
available for this feature, and which one?":**

```ruby
# Family::AutoCategorizer (domain): rules → Bayes → AI for whatever is left
remaining = Family::BayesCategorizer.new(family).classify_and_apply(ids)   # local, always runs
if Ai.available?(:categorize, family:)
  Ai::GenerationJob.perform_later(:categorize, { ids: remaining, family_id: family.id })
end
```

`Ai.available?` is false on an install with AI off, even though categorization still works
locally. Provenance stays in the domain (`enrich_attribute source: "ai"` vs `"bayes"`).

## 4. Configuration

### 4.1 One source of truth, three setups

All instance-wide AI configuration lives in three tables (`ai_endpoints`, `ai_models`,
`ai_routes`) and a few `Setting` fields. The fourth AI table, `ai_endpoint_credentials`, holds
family keys, which are family data (section 4.2). Every process reads the same rows, so the web and the
worker always agree. That removes the "ENV on web vs worker" problem rather than reporting it.

| Setup | Who | How it's configured |
|---|---|---|
| 1. No AI | Anyone | Nothing. No endpoints, so every feature is `:not_configured` and Sure works without AI (section 16). |
| 2. Simple | A self-hoster | Settings → AI → Endpoints. Pick a preset, paste a key, and the preset fills in the URL, models and default routes. |
| 3. Complex | A home lab or a multi-tenant admin | One YAML file, `AI_CONFIG=/config/ai.yml`, on each worker container (every worker runs the `ai` capsule). Loaded into the tables at boot. The instance-wide AI pages become read-only and say "Set by the AI config file". |

The rule is all or nothing. When a config source outside the database is present (`AI_CONFIG`,
or the deprecated AI ENV from section 4.5), it owns every instance-wide AI value; otherwise the UI
owns them. There are no per-field locks and no precedence chain.

**Only processes that run the `ai` capsule load config from outside the database.** The worker's
ENV is what AI jobs read today, so every setup where AI works today has its config on the worker,
whatever the deployment: compose, Helm, quadlets or bare metal. The web container reads the rows
and never loads config, so it doesn't matter which container boots first, how many web replicas
run, or whether the web container has the file or the ENV at all.

Family settings (section 6) are always set in the UI by the family admin. Neither ENV nor the
config file overrides them.

### 4.2 Endpoints and models

```ruby
# app/models/ai_endpoint.rb
class AiEndpoint < ApplicationRecord
  PROTOCOLS = %w[compatible anthropic jev].freeze

  has_many :ai_models, dependent: :destroy
  encrypts :api_key, :extra_headers, :agent_settings     # text columns; the last two hold JSON
  serialize :extra_headers, coder: JSON
  serialize :agent_settings, coder: JSON

  enum :location, { local: "local", cloud: "cloud" }
  enum :json_mode, { auto: "auto", strict: "strict", json_object: "json_object", none: "none" }, prefix: true

  validates :name, presence: true, uniqueness: true
  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :base_url, url: true, allow_blank: true
  validate  :https_for_cloud   # cloud endpoints need https; local ones may use http on a private network
  validates :timeout_seconds, numericality: { greater_than: 0 }

  after_commit { Ai::Config.expire }
end

# columns: name, protocol, preset, base_url, api_key, extra_headers, location, timeout_seconds,
#          json_mode, responses_api (bool), vector_store (bool), agent (bool), agent_settings,
#          parallel_requests (jev only; default 8)
```

```ruby
# app/models/ai_model.rb
class AiModel < ApplicationRecord
  CAPABILITIES = %w[tools vision thinking streaming structured_output embedding judge calibrated_confidence].freeze

  belongs_to :ai_endpoint
  has_many :ai_routes, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :ai_endpoint_id }
  validate  :capabilities_known

  def capable?(*needed) = needed.all? { capabilities.include?(_1.to_s) }

  after_commit { Ai::Config.expire }
end

# columns: ai_endpoint_id, name, capabilities (string[]), context_window, max_output_tokens,
#          batch_size, embedding_dimensions (embedding models only), input_cost_per_mtok,
#          output_cost_per_mtok
```

```ruby
# app/models/ai_route.rb
class AiRoute < ApplicationRecord
  belongs_to :ai_model

  validates :feature, inclusion: { in: Ai::Routes::MATRIX.keys.map(&:to_s) }
  validates :position, uniqueness: { scope: :feature }

  # json_mode: an override for this entry only; nil means the endpoint's own value.
  def json_mode = super || ai_model.ai_endpoint.json_mode

  # prompt: an app/prompts file name for this entry, without locale or .md; nil means the
  # feature's default prompt. Precedence is in section 8.3.
  validate :prompt_file_exists

  # reasoning_effort: one lowercase word sent as the model's reasoning effort for this entry only
  # ("low", "high", "xhigh"...); nil sends nothing and leaves the provider's default (#3605).
  validates :reasoning_effort, format: { with: /\A[a-z]+\z/ }, length: { maximum: 16 }, allow_nil: true
  validate  :reasoning_needs_thinking   # only on a model that declares the thinking capability

  after_commit { Ai::Config.expire }
end

# columns: feature, position, ai_model_id, json_mode (nullable), prompt (nullable),
#          reasoning_effort (nullable)
```

```ruby
# app/models/ai_endpoint_credential.rb — a family's own key for one instance endpoint (#3037)
class AiEndpointCredential < ApplicationRecord
  belongs_to :family
  belongs_to :ai_endpoint
  encrypts :api_key

  validates :api_key, presence: true
  validates :ai_endpoint_id, uniqueness: { scope: :family_id }
  validate  :cloud_endpoint   # a local server's key belongs to the operator; agent endpoints too
end

# columns: family_id, ai_endpoint_id, api_key
```

**A family's own key.** The instance admin still decides endpoints, models and routes. A family
admin may add its own key for any cloud endpoint that isn't an agent, and that family's calls to
the endpoint use it:

- **Which key a call uses.** The family's key if it has one, otherwise the endpoint's own key.
  An endpoint saved with no key of its own is reachable only by families that bring one; that's
  how an operator makes every family pay for its own calls, with no extra setting.
- **No silent fallback.** If a family's key fails, the call doesn't retry with the instance key.
  That would bill the operator and hide the broken key. It fails over to the next route like any
  other failure, and the family admin sees the "AI unavailable" notice naming the key.
- **Down marks per key.** A 429 or 401 on a family's key marks only that key (section 5.4), so
  one household's quota never blocks another.
- **Usage.** `llm_usages` gains `family_key` (boolean), so the usage page shows which calls the
  operator paid for.
- **Never in config.** Family keys are family data. `AI_CONFIG` and the deprecated ENV never
  contain them, and loading either never touches them.

**Three protocols.** A protocol is what the transport speaks, not who runs the server:

| Protocol | Covers |
|---|---|
| `compatible` | The OpenAI API: OpenAI itself, Gemini (through its OpenAI-compatible API), OpenRouter, LiteLLM, llama.cpp, Ollama, vLLM, LM Studio, embedding servers, and the external assistant |
| `anthropic` | Claude, through the native Messages API. Its OpenAI-compatible layer drops features. |
| `jev` | Jev, and anything else that speaks its decisions protocol |

**Flags on `compatible` endpoints:**

- `responses_api`: use the Responses API (strict JSON schemas, `previous_response_id`) instead of
  chat completions. The OpenAI preset sets it. Today's `OPENAI_SUPPORTS_RESPONSES_ENDPOINT` is
  this flag, set by hand.
- `vector_store`: the endpoint offers OpenAI-style vector stores, which the `embed` route can use
  (section 5.5). The OpenAI preset sets it.
- `agent`: the endpoint is an external assistant. Sure sends the chat history with no tools, adds
  the agent headers from `agent_settings` (agent id, session key, the family id header, allowed
  emails), and streams back text. Only `chat` can route to it, and only for families whose chat
  mode is external (section 5.6).

**Capabilities belong to models.** One endpoint serves several models (Opus, Sonnet and Haiku on
one Anthropic key; a chat model and an embedding model on one llama.cpp host), and each model can
do different things. Presets fill in capabilities for known models. For local models the admin
ticks them, and the probe job checks them (section 13). This replaces the native OpenAI model
prefix allow-list: a model is a candidate for a feature only if it declares what the feature
needs, and the probe catches a declaration that's wrong.

**Tuning lives where it applies.** Request timeout and JSON mode are per endpoint, and so is
`parallel_requests`, the size of the Jev transport's request pool (section 7). Context window,
output tokens and batch size are per model, because a small local model needs smaller batches.
A route entry may override `json_mode`, name its own `prompt` file and set a `reasoning_effort`,
for that entry only, so the same model can run with different settings in different routes: a
small model can be given a shorter prompt (sections 8.2, 8.3), and a reasoning model can think
little for `categorize` batches and hard for chat.

**Reasoning effort** (#3605) is per route entry, not global, because the right effort depends on
the work. There's no allowlist: which values a model accepts varies (`gpt-5.4-nano` accepts
`xhigh` and rejects `minimal` and `max`), so any single lowercase word is passed through, and a
value the model rejects comes back as a 400 that the transport's fallback handles (section 7).
Only the `compatible` transport sends it; the Anthropic transport ignores it for now (section 20). The global `llm_context_window`,
`llm_max_response_tokens` and `llm_max_items_per_call` settings go away.

### 4.3 Presets

A preset is a YAML file. Adding a provider means adding a file and a test fixture, with no Ruby.

```yaml
# config/ai/presets/anthropic.yml
name: Anthropic
protocol: anthropic
base_url: https://api.anthropic.com
location: cloud
models:
  - name: claude-sonnet-4-6
    capabilities: [tools, vision, thinking, streaming, structured_output]
    context_window: 200000
  - name: claude-haiku-4-5
    capabilities: [tools, vision, streaming, structured_output]
    context_window: 200000
default_routes:
  chat: claude-sonnet-4-6
  categorize: claude-haiku-4-5
```

```yaml
# config/ai/presets/llama_cpp.yml
name: llama.cpp
protocol: compatible
location: local
json_mode: auto
timeout_seconds: 300
context_probe: llama_cpp_props   # the probe reads the loaded context from /props (section 13)
model_defaults:
  capabilities: [streaming, structured_output]
  batch_size: 10
```

```yaml
# config/ai/presets/jev_local.yml — a self-hosted server speaking Jev's protocol
name: Jev (self-hosted)
protocol: jev
location: local
timeout_seconds: 60
parallel_requests: 1          # one GPU; raise it to match the server's own parallel slots
model_defaults:
  capabilities: [judge]       # no calibrated_confidence until the admin has checked it (section 6)
```

The cloud `jev` preset keeps `parallel_requests: 8`, and its model declares
`[judge, calibrated_confidence]`.

The settings page offers every preset when an admin adds an endpoint. The config file can name a
preset and override any field. The merge rules:

- A scalar field in the config entry replaces the preset's.
- `models:` in the config entry replaces the preset's model list; without it, the entry gets the
  preset's models. Each listed model takes the preset's `model_defaults` for anything it leaves
  out.
- `default_routes` apply only in the UI, and only to features that have no route yet, when an
  admin adds an endpoint. The config file never uses them: its `routes:` is the whole routing.

If the RubyLLM spike is adopted (section 19), a preset's model list can be seeded from RubyLLM's
model registry.

### 4.4 The config file

```yaml
# /config/ai.yml, pointed to by AI_CONFIG
endpoints:
  - name: gpu
    preset: llama_cpp
    base_url: http://llm:8080/v1
    models:
      - name: qwen3-8b
        capabilities: [tools, streaming, structured_output]
  - name: embed                            # same host as gpu, so they share one slot (section 11)
    preset: llama_cpp
    base_url: http://llm:8081/v1
    models:
      - name: nomic-embed-text
        capabilities: [embedding]
  - name: anthropic
    preset: anthropic
    api_key: ${ANTHROPIC_API_KEY}          # secrets stay in the secret store

routes:
  chat:              [anthropic/claude-sonnet-4-6]
  categorize:        [gpu/qwen3-8b, anthropic/claude-haiku-4-5]
  shadow_categorize: [anthropic/claude-haiku-4-5]
  embed:             [embed/nomic-embed-text]
  # chat may also list an agent endpoint; it serves only families whose chat mode is external:
  # chat:              [anthropic/claude-sonnet-4-6, assistant/main]
  # an entry can override json_mode or name its prompt file, for that entry only:
  # categorize:        [{ model: gpu/qwen3-3b, prompt: categorize_transactions_short }, gpu/qwen3-8b]
  # shadow_categorize: [{ model: gpu/qwen3-8b, json_mode: json_object }]
  # categorize:        [{ model: openai/gpt-5.4-nano, reasoning_effort: low }]
  # shadow_categorize: [{ model: gpu/qwen3-8b, prompt: categorize_transactions_trial }]

shadow_rates:
  categorize: 0.1                          # share of categorize calls that also run on shadow_categorize
```

- `Ai::ConfigFile.load!` runs at boot in processes that run the `ai` capsule. It skips the load
  when the file's digest matches `Setting.ai_config_digest`, and takes a Postgres advisory lock so
  two AI workers booting together don't race.
- Each AI worker records the digest it loaded in its Sidekiq process info. If two AI workers have
  different digests, the health page says "AI workers have different AI config" (section 13).
- Endpoints are upserted by `name`, so their ids survive a reload, and so do families' choices of
  allowed endpoints and their own keys. An endpoint removed from the file is deleted, with every
  family key for it.
- `bin/rails ai:export_config` never writes a key in clear. Each key becomes a placeholder named
  after its endpoint (`api_key: ${AI_KEY_ANTHROPIC}`), and a comment at the top lists the
  variables to set. Family keys are never exported.
- Every example key, in `config/ai.example.yml`, the upgrade guide and the contributor guide,
  is a `${VAR}` placeholder, never a key-shaped string, so Pipelock's secret scan passes in CI.
  #4440's example ENV values failed that scan.
- `${VAR}` interpolates from the environment, so keys can come from Docker or Kubernetes secrets.
  Apart from the deprecated path in section 4.5, this is the only place AI secrets are read from
  ENV.
- A file that fails validation stops the boot, with an error naming the line. A half-loaded AI
  configuration is worse than none.

### 4.5 The old AI ENV and settings

Existing installs carry AI configuration in ENV (`OPENAI_ACCESS_TOKEN`, `OPENAI_URI_BASE`,
`OPENAI_MODEL`, `ANTHROPIC_API_KEY`, `JEV_*`, `EMBEDDING_*`, `EXTERNAL_ASSISTANT_*`,
`LLM_PROVIDER`, `VECTOR_STORE_PROVIDER` and the rest) and in `Setting` fields. They take two
paths.

**Installs configured in the UI** migrate with a data migration. The old `Setting` values become
endpoint, model and route rows. It runs inside the database, so no container is involved.
`Setting`'s AI fields take their defaults from ENV (`field :openai_access_token, default:
ENV["OPENAI_ACCESS_TOKEN"]`), so the accessor returns ENV values on an ENV-configured install. The
migration reads only stored rows (`Setting.where(var: ...)`), never the accessors, or it would save
ENV values as if they had been set in the UI.

**Installs configured in ENV** keep working for a deprecation period. The old AI ENV is read as a
generated config file. At boot, an AI worker that finds old AI ENV and no `AI_CONFIG` runs
`Ai::LegacyEnvConfig`:

1. It resolves each old value the way today's code does (ENV, then any value still in the old
   `Setting` fields), so behaviour doesn't change.
2. It builds the same structure as the config file:
   - **Endpoints and models.** `OPENAI_URI_BASE` makes a `compatible` endpoint with
     `responses_api` taken from `OPENAI_SUPPORTS_RESPONSES_ENDPOINT`; without it, the OpenAI
     preset. An endpoint made from `OPENAI_URI_BASE` is `local`, so an http URL that works today
     keeps working under the https-for-cloud rule (section 7). The external assistant becomes a
     `compatible` endpoint with `agent: true`, listed in the `chat` route after the built-in
     model. `JEV_CONCURRENCY` becomes the Jev endpoint's
     `parallel_requests`.
   - **Routes.** One route per feature, using the model today's resolution would pick
     (`LLM_PROVIDER`, then `llm_provider_order`). `embed` uses the embedding endpoint, or the
     OpenAI vector store where today's adapter would use it. On an instance with one family that
     chose Jev for categorization, `categorize` lists Jev first.
3. It loads that through `Ai::ConfigFile`, with the same digest check and the same all-or-nothing
   rule. The instance AI pages are read-only and say "Set by the old AI environment variables
   (deprecated)".
4. It logs a deprecation warning at every boot, naming the variables it found.

There's no import-done flag and no one-time race: every AI worker boot reads the same ENV, and a
matching digest skips the work.

**What counts as old AI ENV.** The source is `:legacy_env` when `AI_CONFIG` is unset and any of
these is set and non-empty: `OPENAI_ACCESS_TOKEN`, `OPENAI_URI_BASE`, `ANTHROPIC_API_KEY`,
`ANTHROPIC_ACCESS_TOKEN`, `ANTHROPIC_BASE_URL`, `JEV_API_KEY`, `JEV_ENDPOINT`,
`EMBEDDING_URI_BASE`, `EXTERNAL_ASSISTANT_URL`. They're the variables that name an endpoint or its
key. A tuning variable alone (`LLM_PROVIDER`, `OPENAI_MODEL`, a timeout) doesn't trigger it; when
the source is `:ui` or `:config_file`, the boot warning names the old tuning variables it found as
ignored. `LANGFUSE_*`, `QDRANT_*`, `AI_DEBUG_MODE`, `RAILS_AI_MAX_THREADS` and the MCP variables
aren't AI model configuration and are never read by this path.

**Where each old variable goes.** The same table drives `Ai::LegacyEnvConfig` and the UI data
migration (each variable's `Setting` field, where it has one, maps the same way):

| Old variable (`Setting` field) | Becomes |
|---|---|
| `OPENAI_ACCESS_TOKEN` (`openai_access_token`) | `api_key` of the OpenAI endpoint, or of the `compatible` endpoint when `OPENAI_URI_BASE` is set |
| `OPENAI_URI_BASE` (`openai_uri_base`) | A `compatible` endpoint named `openai_compatible`, `location: local` |
| `OPENAI_MODEL` (`openai_model`) | A model on that endpoint, listed in every route the OpenAI side served |
| `OPENAI_SUPPORTS_RESPONSES_ENDPOINT` | `responses_api` on the endpoint |
| `OPENAI_SUPPORTS_PDF_PROCESSING` | `vision` on the model |
| `OPENAI_EXTRA_HEADERS` | `extra_headers` on the endpoint |
| `OPENAI_REQUEST_TIMEOUT` (`openai_request_timeout`) | `timeout_seconds` on the endpoint |
| `LLM_JSON_MODE` (`openai_json_mode`) | `json_mode` on the endpoint |
| `OPENAI_REASONING_EFFORT` (`openai_reasoning_effort`), if #3605 merged first | `reasoning_effort` on every route entry the OpenAI side serves |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_ACCESS_TOKEN` (`anthropic_access_token`) | `api_key` of the Anthropic endpoint |
| `ANTHROPIC_BASE_URL` (`anthropic_base_url`) | `base_url` of the Anthropic endpoint |
| `ANTHROPIC_MODEL` (`anthropic_model`) | A model on the Anthropic endpoint |
| `ANTHROPIC_REQUEST_TIMEOUT` | `timeout_seconds` on the Anthropic endpoint |
| `ANTHROPIC_MAX_TOKENS` | `max_output_tokens` on the Anthropic model |
| `LLM_PROVIDER` (`llm_provider`) | Which endpoint's model comes first in each route (`llm_provider_order`) |
| `LLM_CONTEXT_WINDOW` (`llm_context_window`) | `context_window` on each LLM model |
| `LLM_MAX_RESPONSE_TOKENS` (`llm_max_response_tokens`) | `max_output_tokens` on each LLM model |
| `LLM_MAX_ITEMS_PER_CALL` (`llm_max_items_per_call`) | `batch_size` on each LLM model |
| `LLM_MAX_HISTORY_TOKENS`, `LLM_SYSTEM_PROMPT_RESERVE` | Dropped: the chat history budget comes from the model's window (section 8.4) |
| `JEV_API_KEY`, `JEV_ENDPOINT`, `JEV_MODEL` (`jev_*`) | The Jev endpoint (`jev` preset, or `jev_local` for an http URL) and its model |
| `JEV_REQUEST_TIMEOUT`, `JEV_CONCURRENCY` | `timeout_seconds` and `parallel_requests` on the Jev endpoint |
| `CATEGORIZATION_PROVIDER` | Dropped. On a single-family instance whose effective choice is Jev, `categorize` lists Jev first |
| `CATEGORIZATION_CONFIDENCE_THRESHOLD` | Dropped: it overrode a family setting, which ENV no longer does. Upgrade note: set it on the categorization page |
| `CATEGORIZATION_SHADOW_RATE` | `Setting.ai_shadow_rates["categorize"]` |
| `EMBEDDING_URI_BASE`, `EMBEDDING_ACCESS_TOKEN` | A `compatible` endpoint named `embed` and its key; `location: local` for http, `cloud` for https |
| `EMBEDDING_MODEL`, `EMBEDDING_DIMENSIONS` | A model on `embed` with `capabilities: [embedding]` and `embedding_dimensions` |
| `VECTOR_STORE_PROVIDER` | `openai`: the `embed` route uses the OpenAI endpoint's vector store. `pgvector` or `qdrant`: `Setting.vector_store_backend` |
| `EXTERNAL_ASSISTANT_URL`, `_TOKEN`, `_MODEL` (`external_assistant_*`) | A `compatible` endpoint with `agent: true`, its key and model, listed in the `chat` route |
| `EXTERNAL_ASSISTANT_AGENT_ID`, `_SESSION_KEY`, `_ALLOWED_EMAILS` | `agent_settings` on that endpoint |
| `ASSISTANT_TYPE` | Dropped: chat mode is a family setting (section 6) |
| `ASSISTANT_MAX_TOOL_CALL_ITERATIONS` | `Setting.ai_max_tool_rounds` |
| `AI_RESPONSE_TIMEOUT` (`ai_response_timeout`) | `Setting.ai_response_timeout` |
| `AI_HEALTH_PROBE_TIMEOUT` (`ai_health_probe_timeout`) | Dropped: probes use the endpoint's timeout |
| `AI_HEALTH_PROBE_CACHE_TTL` | Dropped: today's default becomes a constant in `AiHealth::Probe` |

**Leaving the old ENV.** The warning also appears as a banner for the instance admin on the AI
settings pages. Both name the command `bin/rails ai:export_config > ai.yml`, which writes the
equivalent config file. The operator then either mounts it as `AI_CONFIG`, or removes the
variables and manages AI in the UI. The upgrade guide names the release that stops reading the
old variables; that release deletes `Ai::LegacyEnvConfig` and the old `Setting` fields.

### 4.6 Instance values on `Setting`

Four instance-wide values stay on `Setting`, without ENV:

```ruby
field :vector_store_backend,    type: :string,  default: "pgvector",
                                validates: { inclusion: { in: %w[pgvector qdrant] } }
field :ai_max_tool_rounds,      type: :integer, default: 8    # was ASSISTANT_MAX_TOOL_CALL_ITERATIONS
field :ai_response_timeout,     type: :integer, default: 90   # exists today; AI_RESPONSE_TIMEOUT no longer overrides it
field :ai_shadow_rates,         type: :hash,    default: {}   # feature key => 0..1, e.g. { "categorize" => 0.1 }
```

`ai_max_tool_rounds` and `ai_response_timeout` bound a chat turn (section 5.5). The deprecated ENV path maps
`ASSISTANT_MAX_TOOL_CALL_ITERATIONS` and `AI_RESPONSE_TIMEOUT` onto them.
`ai_health_probe_timeout` and `AI_HEALTH_PROBE_TIMEOUT` go: probes use each endpoint's
`timeout_seconds` (section 13). `ai_shadow_rates` replaces the family's
`categorization_shadow_rate`: an instance with one family copies its rate, any other starts at 0
with an upgrade note (section 8.2). The config file sets it as `shadow_rates:`.

They're set on the instance-wide AI pages, or in the config file, under the same all-or-nothing
rule. Changing any of them requires `User#manages_instance_settings?`, which is true for super
admins and for the admin of the only family on a self-hosted install.

`Ai::Config.current` returns a frozen snapshot of the three tables and these values, plus
`source` (`:ui`, `:config_file` or `:legacy_env`), which the loader stores. Each process caches it
and checks a version stamp in `Rails.cache` (`ai/config/version`) at the start of every job, which
costs one cache read. The stamp is bumped by an `after_commit` on `AiEndpoint`, `AiModel`,
`AiRoute` and `AiEndpointCredential`, by a write to any of the four AI `Setting` fields, and by
the config loader after it loads. The web reads `source` to decide whether the instance-wide
pages are read-only; it never looks for the file or the ENV itself.

### 4.7 No new AI ENV

ENV variables are permanent once released, they differ between containers, and coding agents add
them by default because it's the shortest path. The cop `Sure/NoAiEnv` flags any `ENV[...]` or
`ENV.fetch` read of an AI-looking name (`OPENAI_*`, `ANTHROPIC_*`, `LLM_*`, `JEV_*`,
`EMBEDDING_*`, `AI_*`, `CATEGORIZATION_*`, `ASSISTANT_*`, `EXTERNAL_ASSISTANT_*`,
`VECTOR_STORE_*`) outside `app/models/ai/config_file.rb` and `app/models/ai/legacy_env_config.rb`.
The second entry goes when the deprecated variables stop being read. Its message points to the
right place:

> AI configuration lives in the `ai_*` tables and the AI config file, not in ENV. Add a column,
> a preset field or a config file key instead. See `docs/llm-guides/ai-pipeline.md`.

`LANGFUSE_*`, `AI_DEBUG_MODE` (an operator's logging switch) and the proxy variables aren't AI
configuration and aren't flagged.

## 5. Routing

### 5.1 The routing table (code)

Code defines each feature: its lane, what its models need, its consent level and the data it
sends. Changing any of these changes what data leaves the box, so it goes through review and the
architecture tests and can't be changed at runtime.

```ruby
# app/models/ai/routes.rb — THE routing table.
module Ai::Routes
  MATRIX = {
    chat:              { lane: :interactive, needs: %i[tools streaming],        consent: :user,
                         sends: %i[chat_messages looked_up_financial_data] },
    bill_setup:        { lane: :interactive, needs: %i[structured_output],      consent: :user,
                         sends: %i[transaction_dates transaction_amounts transaction_names category_names bill_configuration] },
    extract_pdf:       { lane: :prompt,      needs: %i[vision structured_output], consent: :user,
                         sends: %i[uploaded_document] },
    embed:             { lane: :prompt,      needs: %i[embedding],              consent: :user,
                         sends: :depends_on_vector_store },
    search_documents:  { lane: :interactive, route_of: :embed, consent_as: :embed, consent: :user,
                         sends: %i[search_query] },
    categorize:        { lane: :background,  needs: { generation: %i[structured_output], judgement: %i[judge] }, consent: :family,
                         sends: %i[transaction_names transaction_amounts provider_category_hints category_names] },
    shadow_categorize: { lane: :background,  shadow_of: :categorize,            consent: :family },
    detect_merchants:  { lane: :background,  needs: %i[structured_output],      consent: :family,
                         sends: %i[transaction_names merchant_names] },
    enhance_merchants: { lane: :background,  needs: %i[structured_output], consent_as: :detect_merchants, consent: :family,
                         sends: %i[merchant_names] }
  }.freeze

  QUEUES = { interactive: "ai_interactive", prompt: "ai_prompt", background: "ai_background" }.freeze

  def self.fetch(feature)     = MATRIX.fetch(feature)
  def self.queue_for(feature) = QUEUES.fetch(fetch(feature)[:lane])
  def self.needs_for(feature) = fetch(source_of(feature)).fetch(:needs)                    # follows shadow_of and route_of
  def self.source_of(feature)   = fetch(feature).values_at(:shadow_of, :route_of).compact.first || feature
  def self.consent_key(feature) = fetch(feature).values_at(:shadow_of, :consent_as).compact.first || feature
  # Everything sent under one consent key: a row on the AI features page covers its whole group.
  def self.sends_for(key) = MATRIX.select { |f, _| consent_key(f) == key }.flat_map { |_, spec| Array(spec[:sends]) }.uniq
end
```

- `extract_pdf` covers two generations, `ReadPdf` and `ExtractBankStatement`. They send the same
  data under the same consent.
- **One consent row per thing a person recognises.** `consent_as:` puts a feature under another's
  consent: `search_documents` under `embed` ("Documents") and `enhance_merchants` under
  `detect_merchants` ("Merchants"). The AI features page shows six rows: Chat, Bills
  (`bill_setup`), PDF import (`extract_pdf`), Documents, Categories (`categorize`, and its shadow
  runs) and Merchants. Each row's manifest is everything its group sends (`sends_for`). Feature
  keys, routes, lanes and usage stay per feature.
- "Dig in with AI" and the bills AI review are chats, so they use `chat`.
- `shadow_categorize` inherits `needs` and `sends` from `categorize`.
- `search_documents` (the `search_family_files` tool, from chat or MCP) has no model list of its
  own: it uses `embed`'s route and needs, because a query vector must come from the same model as
  the stored ones, or the same vector store. Its lane is interactive, because someone is waiting.
- `Ai::Routes.needs_for(feature)` follows `shadow_of` and `route_of`, so the router checks
  capabilities against the feature the needs come from.
- A hash of needs (`categorize`) means the feature has a generation and a judgement: a route
  qualifies if its model meets either set, and the plumbing picks the class per route
  (section 8.1).
- There's one chat feature. Every chat entry point (the chat page, the API, "Dig in with AI", the
  bills AI review, #3442) asks for `chat`. The `chat` route can list model routes and agent
  endpoints, and the family's chat mode picks which kind serves it (section 5.3). An agent
  endpoint never serves any other feature, so an external assistant never receives background
  work.
- The kind of call (generation, judgement, conversation, embedding) comes from the class that
  declares the feature, not from a field.
- `embed`'s manifest depends on the route: whole files go to an OpenAI vector store, or chunks to
  an embedding model.

**Feature keys.** A key appears in config files, `llm_usages.operation`, `families.ai_consents`,
Langfuse trace names and i18n keys, so it's chosen once:

- It's the shortest name an admin would recognise on the usage page, which sums usage per
  feature. (The AI features page shows six row labels instead, section 6.)
- It's snake_case and never names a provider or a model.
- A shadow route is `shadow_<feature>`.
- Once released, it's permanent. Renaming one needs a migration and an upgrade note.

Class names stay descriptive and declare their key: `CategorizeTransactions` declares
`feature :categorize`.

### 5.2 Routes (configuration)

Configuration gives each feature **one ordered list of models**:

```
chat              → anthropic/claude-sonnet-4-6
categorize        → gpu/qwen3-8b, anthropic/claude-haiku-4-5
shadow_categorize → jev/jev-latest
embed             → embed/nomic-embed-text
```

The first model is the normal choice. A later one is used only when an earlier one's server is
down (failover) or the earlier model can't handle the request (escalation). A busy local host
isn't a reason to move on: the call waits for it or re-enqueues (section 11), so work never
leaves for the cloud just because the local model is busy. One list covers all three, so there's
no separate duty, standby, failover or escalation setting. A feature with no list is
`:not_configured`.

Two local servers are two endpoints in the same list. A family that blocks the cloud endpoint
(section 6) never reaches the second entry.

### 5.3 The router

One function answers "for this feature, for this family and user, what may run, and why not?".

```ruby
# app/models/ai/router.rb
class Ai::Router
  def initialize(family:, user: nil) = (@family, @user = family, user)

  # @return [Ai::Plan, Ai::Availability(unavailable)]
  def resolve(feature)
    spec   = Ai::Routes.fetch(feature)
    listed = Ai::Config.current.routes_for(spec[:route_of] || feature)
                                .select { |route| route.agent? == agent_chat?(feature) && route.serves_user?(@user) }   # agent allowed emails
    return Ai::Availability.unavailable(:not_configured) if listed.empty?   # first: nothing to consent to

    if (reason = Ai::Consent.denial(feature, spec, family: @family, user: @user))
      return Ai::Availability.unavailable(reason)
    end

    capable = listed.select { |route| route.agent? || route.model_capable?(Ai::Routes.needs_for(feature)) }
    allowed = capable.select { |route| @family.ai_endpoint_allowed?(route.endpoint) }
    keyed   = allowed.filter_map { |route| route.with_key_for(@family) }   # family key, else endpoint key, else dropped

    return Ai::Availability.unavailable(:capability_missing)   if capable.empty?
    return Ai::Availability.unavailable(:endpoint_not_allowed) if allowed.empty?
    return Ai::Availability.unavailable(:key_missing)          if keyed.empty?

    Ai::Plan.new(feature:, lane: spec[:lane], routes: keyed)
  end

  private
    # An agent endpoint serves chat for families whose chat mode is external, and nothing else.
    def agent_chat?(feature) = feature == :chat && @family.chat_mode_external?
end
```

- **Chat mode chooses the routes, not the feature.** A family in external mode gets only the
  agent endpoints in `chat`'s list; a family in built-in mode gets only the model routes. Every
  chat entry point asks for `chat` either way. An external family with no agent endpoint in the
  list resolves to `:not_configured`.
- `Ai.available?(feature, family:, user:)` and `Ai.availability(...)` wrap `resolve` and replace
  every check in the table in section 1. `User#ai_available?` becomes a one-line delegate, kept
  for the API and the mobile auth payload.
- `preferred_llm_provider`, `llm_provider_order`, `Family#resolved_categorization_provider`,
  `#shadow_categorization_provider`, `#categorization_model_name`, `Chat.default_model` and
  `Assistant::Provided#get_model_provider` are deleted with their 87 test stubs: the non-chat
  ones in PR 2, the chat ones in PR 3.
- The code above is the final shape. The family consent checks arrive in PR 6, and the
  `allowed` and `keyed` lines in PR 8 (section 6).
- The router doesn't look at liveness. Down endpoints and busy slots are the sequencer's concern
  at run time (section 11), so availability doesn't flicker when a worker restarts.

### 5.4 Failover, escalation and what the user sees

- **No overflow.** The sequencer takes the first route in the plan that isn't marked down. If its
  local host is busy, the call waits or re-enqueues (section 11); it doesn't move to the next
  entry.
- **Failover: the endpoint is unhealthy.** On `Ai::Error::Timeout`, `Upstream`, `RateLimited`,
  `Unreachable` or `Unauthorized`, the generation retries once on the next route on a different
  server (a different normalised base URL), and the failed one is marked down.
- **Escalation: this model can't handle this request.** On `Ai::Error::InvalidOutput` or
  `ContextTooLong`, the generation retries once on the next route, which may be a bigger model on
  the **same** endpoint (a 3B and a 20B on one llama.cpp host). Nothing is marked down: the
  endpoint is fine, and other requests may suit the small model. `InvalidOutput` is raised only
  after the transport's own JSON-mode fallbacks and tolerant parsing have failed, so the small
  model really couldn't do it.
- **No retry on other `Refused` errors.** A malformed request is our bug, and every model would
  refuse it.
- **Limits.** Each call fails over or escalates at most once. If the last route also fails, the
  error stands. Both only use routes the admin listed and the family allows, and the failed
  call's usage is still recorded.
- **Down marks.** The router marks the failure down in `Rails.cache` for 60 seconds, so the next
  call skips it without waiting for the same timeout. A fresh failed probe result marks it down
  too. Connection failures (`Timeout`, `Upstream`, `Unreachable`) mark the **server**, keyed by
  normalised base URL (host and port: a chat server can be down while the embedding server on the
  same host is up), so every endpoint row on that server is skipped. `RateLimited` and
  `Unauthorized` mark only the **key**: the endpoint row with its own key, or the endpoint row and
  family when a family brought its own (section 4.2). A quota or key problem is the key's, not the
  server's, so one family's 429 never blocks another family or the instance key.
- **What the user sees.** Chat shows the serving model below the message input
  (`claude-sonnet-4-6 · Anthropic`) and says so after a failover
  (`claude-sonnet-4-6 · Anthropic (gpu unreachable)`) or an escalation
  (`gpt-oss-20b · gpu (escalated: qwen3-3b output invalid)`). The assistant message stores the
  route that served it. One-shot dialogs show the same line in their footer. Background failovers
  and escalations write a `DebugLogEntry`.
- **The "AI unavailable" notice.** When a feature the family has consented to resolves to
  unavailable, or every route in its plan is down, the family admin sees it as that row's status
  on the AI features page and in a dismissible banner that links to the row: "Categorization is
  unavailable: no allowed endpoint is reachable." Nothing is stored: the status is worked out on
  each page load from `Ai.availability` and the down marks. Dismissing the banner hides it for
  that user until they next sign in (a session value); the row still shows it.

### 5.5 Chat continuation and the vector store

- **Chat on a `responses_api` endpoint** continues the conversation with `previous_response_id`
  when the previous turn ran on the same endpoint. Otherwise, including after a failover, chat
  sends the history rebuilt from `messages`. Failover happens only at the start of a turn, never
  in the middle of a stream, because a turn's provider state can't move.
- **Bounded turns.** `Ai::Conversation` owns the tool loop, whatever the spike decides
  (section 19), and bounds it twice: at most `Setting.ai_max_tool_rounds` rounds, with the last
  round sent without tools so the model must answer, and at most `Setting.ai_response_timeout`
  seconds for the whole turn, after which the turn stops and the message says so. Today's
  responder already caps rounds; the cap moves into the plumbing so every transport and the
  RubyLLM adapter get it. When chat runs on an agent endpoint, Sure can't see the agent's own
  loop, so only the turn timeout applies.
- **The `embed` route picks the vector adapter.** If its endpoint has `vector_store`, documents go
  to an OpenAI-style vector store, and the manifest says whole files are sent. Otherwise chunks go
  to the route's embedding model and are stored in `Setting.vector_store_backend` (pgvector or
  Qdrant). `VECTOR_STORE_PROVIDER` is read through the deprecated ENV path (section 4.5).

### 5.6 The external assistant

The external assistant is an agent, not a model. It has its own model, memory and tools, and it
calls Sure back over the MCP server. It's a `compatible` endpoint with `agent: true`, listed in
the `chat` route, and it serves only families whose chat mode is external (section 5.3). It never does background work: background features need Sure's
prompts, structured output and usage records, which an agent doesn't promise. An operator who
wants every call to go through their own stack points a plain `compatible` endpoint at it for
background work and keeps the agent for chat.

## 6. Consent and family settings

The household's financial data belongs to the family, so the family decides what may leave the
box. Each person then decides whether they use AI themselves.

**One concern.** Every family AI setting below, and the methods that read them
(`chat_mode_external?`, `ai_consented?`, `ai_endpoint_allowed?`, the family's
keys), lives in `Family::AiSettings`, a concern in `app/models/family/ai_settings.rb`.
`family.rb` has about 20 open PRs at any time, so it gains only one `include`.
`Family::AiPromptable` stays as it is.

**Delivery.** PR 2 ships `Ai::Consent` with the user switch, plus the
threshold and prompt overrides; PR 3 adds chat mode. PR 6 creates the AI features page with chat
mode and per-feature consent (`families.ai_consents`, the consent migration, member emails,
`:no_family_consent`, `:consent_outdated`), which fixes drift bug 4. PR 8 adds the family's
allowed endpoints, its own keys and the member switch as new sections of that page. Until each
lands, the router has no line for it: before PR 6 background features run without family
consent, as today. One rule is carried over rather than stubbed: today `mcp_only` turns chat
off (through `User#ai_available?`), so PR 3, which deletes that check, keeps the rule as one line
in `Ai::Consent` (`:no_family_consent` for `chat` when `assistant_type` is `mcp_only`). PR 6
deletes the line when the consent migration turns those families' Chat row off.

**Two family AI pages.** The AI features page holds everything about what AI the family uses: six
rows (Chat, Bills, PDF import, Documents, Categories, Merchants), each with its switch, manifest
and status ("On", "Off", "Unavailable: no model can read PDFs", with the fix beside it); chat mode
as the Chat row's selector; the endpoints section; and the members section. The categorization
page is about the categorization workflow (the confidence threshold), so it stays separate.
Prompts sit behind an "Advanced" link at the bottom of the AI features page; usage keeps its own
page. There's no separate overview page: the rows' status is the overview.

**Only controls that do something.** A control appears only where it changes something:

| Control | Shown when |
|---|---|
| Chat mode | The `chat` route lists an agent endpoint |
| Endpoint checkboxes | The instance has more than one endpoint (the list, with local and cloud labels, always shows) |
| Own-key field | The admin doesn't manage the instance, or the endpoint has no key of its own |
| Members section | The family has more than one member |
| Confidence threshold (categorization page) | A model with `calibrated_confidence` is in the `categorize` route; otherwise the page says every answer is applied as it comes |
The `sends:` manifest is in the routing table from PR 2, so the generated docs table shows what
each feature sends before the AI features page exists.

```ruby
module Ai::Consent
  # @return [Symbol, nil] the reason the feature is denied, or nil when it's allowed
  def self.denial(feature, spec, family:, user:)
    consent_key = Ai::Routes.consent_key(feature)
    return :no_family_consent unless family.ai_consented?(consent_key)
    return :consent_outdated  unless family.ai_consent_covers?(consent_key, Ai::Routes.sends_for(consent_key))
    return :blocked_by_admin  if spec[:consent] == :user && user && !user.ai_allowed?
    return :user_disabled     if spec[:consent] == :user && !user&.ai_enabled?
    nil
  end
end
```

**Family settings**, all set by a family admin, never by ENV or the config file:

| Setting | Column | Default |
|---|---|---|
| Each row on or off (a consent key: six rows), on the AI features page with its data manifest and where the data may go (PR 6) | `families.ai_consents` (jsonb) | See the migration below |
| Chat mode: built-in or external | `families.chat_mode`, a string with a check constraint on `built_in`, `external` | From `assistant_type`: `builtin` → `built_in`, `external` → `external`, `mcp_only` → `built_in` with chat switched off |
| Endpoints this family allows (PR 8) | `families.ai_blocked_endpoint_ids` | None blocked. A new endpoint is allowed at once. |
| The family's own key per cloud endpoint (PR 8) | `ai_endpoint_credentials` (section 4.2) | None: the endpoint's own key is used |
| Members allowed to use AI (PR 8) | `users.ai_allowed` (boolean, set only by a family admin) | `true` for every member, guests included |
| Categorization confidence threshold | `families.categorization_confidence_threshold` | 0.7, today's schema default. The code comment that says 0 is fixed. |
| Prompt overrides, one per feature | `families.ai_prompt_overrides` | Migrated (section 8.3) |

- **One place for AI features.** The AI features page is where a family admin turns each AI
  feature on or off. A maintainer asked for this in discussion #203: "one single place in
  `settings/` ... to turn different things on/off", rather than more flags and ENV. Turning a
  feature on is the family's consent to send what its manifest lists.
- **Two levels.** Family consent per feature decides what may send this household's data off the
  box. The existing `users.ai_enabled` switch decides whether a person uses AI. Background
  features need family consent; chat, bills, PDF import, embedding and document search also need
  the user's switch.
  One member can't consent for everyone, which fixes drift bug 4.
- **Consent covers what was shown.** `families.ai_consents` stores, per feature, the `sends:`
  keys the family admin agreed to. A feature counts as consented only while its current `sends:`
  list is within the agreed one. The column holds one entry per consented feature:
  `{ "categorize" => { "sends" => [...], "at" => "<ISO 8601>", "by" => "<user id>" } }`, so who
  consented and when is recorded (M5). For `embed`, whose manifest depends on the route,
  `sends:` resolves per adapter: `whole_documents` for a vector store endpoint, `document_chunks`
  for an embedding model, so moving `embed` to a vector store re-asks. When a release makes a feature send more (for example
  categorization starting to send account names), that feature resolves to `:consent_outdated`
  until a family admin reviews it on the AI features page, and members get the usual notice when
  it's turned back on. A feature that sends less, or whose wording changes, isn't re-asked.
- **Consent migration.** Every feature is consented for families where any member has
  `ai_enabled` today, with its current `sends:` keys, except chat for families whose
  `assistant_type` is `mcp_only`. `categorize` and `detect_merchants` are also consented for families with
  active AI rules, because rule-driven AI runs today without anyone's consent. Families with
  neither start with every feature off.
- **New families start with every feature off.** Their first visit to the AI features page shows
  each row's manifest with "Turn on", and "Turn on all" for convenience. Members get one email
  for the background rows turned on together.
- **Members are told.** When a family admin turns on a background feature, every member gets an
  email (`AiConsentMailer`), because their transactions will be sent. Sure has no in-app
  notifications, so email is the one channel every member already has.
- **Where the data may go.** The AI features page shows each feature's manifest in plain language and
  the endpoints its route may use, marked local or cloud: "Categorization sends: transaction
  names and amounts, your category names. It may use: gpu (local), Anthropic (cloud)."
- **Allowed endpoints.** The endpoints section of the AI features page lists every instance endpoint,
  marked local or cloud, even when there's only one. With more than one, each has a checkbox,
  ticked by default. A tooltip says "Your instance admin adds endpoints on the AI
  endpoints page or in the AI config file." Unticking every cloud endpoint is how a family keeps
  its data local.
- **Own keys.** A cloud endpoint in the same section has a "use our own key" field, masked like
  every key, when the admin doesn't manage the instance or the endpoint has no key of its own.
  On a self-hosted install the admin who manages the instance puts the key on the endpoint. Saving it enqueues a probe with that key (the web never calls a model), and the
  result arrives by Turbo Stream. An endpoint with no key of its own says "Bring your own key to
  use this endpoint".
- **Members.** The members section of the AI features page lists every member with a switch,
  on by default. It shows when the family has more than one member. A family admin can turn a member off but never on: turning AI on stays the
  member's own consent (`users.ai_enabled`). A member who is off sees "Your family admin has
  turned AI off for you" (`:blocked_by_admin`) instead of the consent prompt, and can't turn
  their own switch back on. It covers only AI the member starts (chat, bill suggestions, PDF
  import, document search). Background features still process the member's transactions,
  because they run on family consent; keeping a member's accounts out of them is out of scope
  (section 20). Guests are forced on today because the intro layout depends on chat; a guest
  who is turned off sees the same "AI unavailable" screen an `mcp_only` guest sees today.
- **Turning chat off** is chat's switch on the AI features page, like any other feature. It
  makes `chat` unavailable (`:no_family_consent`), and with it every chat entry point: the chat
  page, the API, "Dig in with AI" and the bills AI review. Every other feature is unaffected, and
  MCP keeps working, as it does today for `mcp_only` families. Chat mode only chooses built-in or external.
  Today `mcp_only` also turns off bill AI, because `User#ai_available?` returns false; that side
  effect goes away.
- **The confidence threshold gates only calibrated confidence.** Calibration is a fact about the
  model, so it's a model capability, `calibrated_confidence`, supplied by presets: the cloud `jev`
  preset declares it; `jev_local` and the LLM presets don't. The threshold stays a family
  preference (how much to trust automatically, F3), one number that works across models because
  only calibrated scales are compared with it.
  - An answer from a model with `calibrated_confidence` that falls below the threshold, or arrives
    with no confidence at all, isn't applied, and the transaction stays as Bayes and the rules
    left it. For cloud Jev this is exactly what `Family::AutoCategorizer#withhold?` does today.
  - Answers from other models (LLMs, a self-hosted judge not yet checked) stay ungated.
  - Any confidence a model returns is recorded in `DataEnrichment.metadata` and `Ai::Comparison`.
    The health page's per-model agreement figures (section 13) show whether a self-hosted judge's
    confidence tracks agreement, which is what an admin checks before ticking
    `calibrated_confidence`.
- **No family provider choice.** `categorization_provider` and the `ASSISTANT_TYPE` and
  `CATEGORIZATION_PROVIDER` ENV overrides are removed. Jev is an entry in a route like any other
  model.
- **Known limitation:** family consent covers every account in the family, including accounts not
  shared with every member. Filtering each feature's input by account owner belongs to the domain
  workflows, not the plumbing.

## 7. Transports — one structured-output primitive each

Whether transports are hand-written or a thin adapter over RubyLLM is decided by the spike
(section 19). The interface is the same either way, and Jev stays hand-written.

```ruby
class Ai::Transport::Base
  # Request = Data.define(:model, :instructions, :input, :schema, :schema_name, :max_tokens, :reasoning_effort, :attachments, :metadata)
  def generate(request)            = raise NotImplementedError   # → Response(json:, usage:, raw_id:)
  def converse(request, &on_chunk) = raise NotImplementedError
  def judge(state:, questions:)    = raise NotImplementedError
  def embed(texts)                 = raise NotImplementedError
  def probe(model)                 # health probes reuse the production path (fixes drift bug 6)
end
```

| Transport | `generate` strategy |
|---|---|
| `Compatible` with `responses_api` | `responses.create` + `text.format = json_schema, strict: true` |
| `Compatible` without it | chat completions with the route's `json_mode` (the entry's override, otherwise the endpoint's) (`strict` → `json_object` → `none`). `auto` falls back when the null ratio exceeds 50% or a 400 comes back. Tolerant parsing (`<think>`, fenced JSON); a schema example is appended in `none` mode. |
| `Anthropic` | `messages.create` with one tool whose `input_schema` is the schema, `tool_choice: {type: "tool"}`. Models that reject a forced tool get `auto`, an instruction to call it, and one retry when they answer with text (#4513). |
| `Jev` | doesn't implement `generate`; implements `judge` |

- **Reasoning effort.** `Compatible` sends the route entry's `reasoning_effort` as
  `reasoning: { effort: }` on the Responses API and `reasoning_effort` on chat completions, and
  leaves it out when unset. When a request with `response_format` or an effort gets a 400, the
  JSON-mode fallback retries once without both (as #3605 does); a retry after unusable output
  keeps the effort. Probes never send it. `Anthropic` ignores it for now.
- `Compatible` also implements `embed` and the vector store calls, and its agent mode for chat on
  an agent endpoint. It replaces `Provider::Openai`, the compatible code paths and
  `Assistant::External::Client`.
- **`Ai::Transport::Http` builds every client.** It applies the endpoint's timeout and extra
  headers, and it resolves the proxy once (`HTTPS_PROXY`, then `HTTP_PROXY`, honouring
  `NO_PROXY`) and passes it to every client, including Anthropic's. A contract test checks that
  every transport uses it. The `# pipelock:ignore` annotations collapse into this file and the
  config loader.
- **Anthropic batches are token-sliced** like the others, using the model's `context_window`.
- **Jev fans out inside one call.** Jev's API takes one transaction per request, and each request
  is latency-bound (~400–550 ms), so `judge` runs a batch on a bounded pool of
  `parallel_requests` threads (default 8, today's `DEFAULT_CONCURRENCY`): about 1.6 s for 25
  transactions instead of about 12 s. Everything above the transport sees one batch call, as it
  does for an LLM. Cloud Jev has no sequencer slot; a self-hosted Jev holds its host's one slot
  for the whole batch, because its internal requests are its own concern, like the requests inside
  an LLM batch. Counting each request as a slot would run Jev one request at a time.
- **A self-hosted Jev-compatible server** is the same transport with the `jev_local` preset. Its
  `parallel_requests` defaults to 1, because the sequencer can't see requests inside a call, and 8
  at once would overload the host's GPU or CPU (H2).
- **https only for cloud endpoints.** Today `Provider::Jev.endpoint_allowed?` refuses http except
  on loopback, which rules out `http://jev:8080` on a compose network. `AiEndpoint` now requires
  https for `cloud` endpoints of every protocol and allows http for `local` ones, as `compatible`
  endpoints already do. A private network is the operator's call; financial data and keys on the
  public internet still need TLS.
- **Transports run only inside the `ai` capsule.** In development and test, `Base` raises when
  it's called anywhere else: a web thread, a rule job, a default-queue job. An LLM call added in
  the wrong place fails its tests, and every call goes through the sequencer. Evals and console
  sessions opt in explicitly with `Ai::Sequencer.outside_capsule { ... }`, which takes a slot in
  their own process and is never used in app code (the cop allow-list is `lib/eval/**`).

## 8. Generations, shadow runs and prompts

### 8.1 `Ai::Generation` — the file a coding agent copies

A feature is declared, not implemented. This replaces both `Provider::Openai::BillSetupSuggester`
(169 lines) and `Provider::Anthropic::BillSetupSuggester` (178 lines):

```ruby
# app/models/ai/generations/suggest_bill_setup.rb
class Ai::Generations::SuggestBillSetup < Ai::Generation
  feature :bill_setup                      # → routing table row: lane, needs, consent, data manifest
  prompt  :bill_setup                      # default → app/prompts/bill_setup.md (section 8.3)

  SCHEMA = {
    type: "object",
    properties: {
      name:          { type: %w[string null] },
      amount:        { type: %w[number null] },
      frequency:     { type: %w[string null], enum: RecurringTransaction::FrequencyPreset::PRESETS + [ nil ] },
      day_of_month:  { type: %w[integer null], minimum: 1, maximum: 31 },
      weekday:       { type: %w[integer null], minimum: 0, maximum: 6 },
      month_of_year: { type: %w[integer null], minimum: 1, maximum: 12 },
      category_name: { type: %w[string null] },
      bill_type:     { type: %w[string null], enum: [ "bill", "subscription", "installment", nil ] },
      autopay:       { type: %w[boolean null] },
      confidence:    { type: %w[number null], minimum: 0, maximum: 1 },
      rationale:     { type: %w[string null] }
    },
    required: %w[name amount frequency day_of_month weekday month_of_year category_name bill_type autopay confidence rationale],
    additionalProperties: false
  }.freeze
  schema SCHEMA

  def initialize(charges:, categories:, current_config: nil)
    @charges, @categories, @current_config = charges, categories, current_config
  end

  def prompt_locals = { configure_mode: @current_config.present? }

  def input
    lines = @charges.map { |c| "- #{c[:date]} #{c[:amount]} #{c[:name]}" }
    <<~TEXT
      CHARGE HISTORY (date amount description):
      #{lines.join("\n")}

      AVAILABLE CATEGORIES: #{@categories.join(", ")}
      #{"CURRENT CONFIGURATION:\n#{@current_config.to_json}" if @current_config.present?}
    TEXT
  end
end
```

`Ai::Generation#call` is the only place that does these things, in this order:

1. `Ai::Router#resolve(feature)`. Unavailable returns `Ai::Result.unavailable(reason)`.
2. Stop if `cancelled` returns true.
3. `Ai::Sequencer.run(plan) { |route| ... }` picks the route (section 11). Inside the block, because
   the prompt belongs to the chosen route entry and the batch size to the chosen model:
   - render the prompt: `Ai::Prompt.for(key, route:, family:, locale:)`, which applies the
     precedence and locale rule in section 8.3;
   - take the next batch when the feature declares `batch`, sized by the model's `batch_size` and
     `context_window` (this moves `Provider::Openai::BatchSlicer` here, for every transport);
   - call `route.transport.generate(request)`.

   On a failover error, retry once on the next route on a different server; on an escalation
   error, retry once on the next route, whatever its endpoint (section 5.4). Coercion and
   validation (step 4) run inside this retry, so invalid output can escalate.
4. Coerce and validate the JSON against `schema` (`Ai::Schema`): `"null"` → nil, numeric strings →
   numbers, unknown enum values → nil, invalid → `Ai::Error::InvalidOutput`.
5. `ActiveSupport::Notifications.instrument("generate.ai", feature:, route:, usage:, error:, family:, correlation_id:, shadow: false)`.
6. If the call succeeded and the feature has a shadow route, sample the instance's shadow rate for
   the feature (`Setting.ai_shadow_rates`) and,
   on a hit, enqueue `Ai::ShadowJob`.
7. Return `Ai::Result`. The job enqueues the remaining batches (section 11).

`call` always returns an `Ai::Result`. `call!` returns the value or raises the `Ai::Error`; jobs
use `call!` so `retry_on` and `discard_on` work (section 9). There is no per-feature failure
option. Batched features declare how batch outputs combine, for example
`merge :categorizations, by: :transaction_id`.

**Batches.** `batch :transactions` names the initializer keyword that holds the items. Inside the
sequencer block, once the route is known, the plumbing:

1. slices that list with `Provider::Openai::BatchSlicer`'s rule, moved to `Ai::Batch`: at most the
   model's `batch_size` items, and at most the tokens that fit in `context_window` minus
   `max_output_tokens`, estimated from the rendered prompt plus `input`;
2. builds a copy of the generation holding only the first slice (`with_items(slice)`), so `input`
   only ever sees one batch;
3. runs that copy, and returns the rest as `Ai::Result#remaining`.

`call(batches: 1)` runs one batch and is what jobs use (small batches, section 11). Plain `call`
runs every batch in turn and merges the outputs; evals and tests use it.

**Generation or judgement.** A feature may declare both, as `categorize` does. The router keeps a
route if its model meets either set of needs (`structured_output` for the generation, `judge` for
the judgement). The plumbing picks the class per route: the judgement for a `judge` model, the
generation otherwise, so failover from Jev to an LLM switches class. Both return the same value
shape (`{ categorizations: [{ transaction_id:, category_id:, confidence: }] }`); the judgement maps
Jev's `DecisionSet` into it. The domain sees one shape and applies the threshold by the serving
model's `calibrated_confidence` (section 6), which `Ai::Result#route` carries.

**The owner: the domain side of a feature.** Every generation and judgement feature has one
owner, a domain class that rebuilds itself from job arguments, makes the generation and applies
the result. `Ai::GenerationJob` talks only to the owner, so it never knows what categorizing or
reading a PDF means:

```ruby
# app/models/ai/owner.rb
module Ai::Owner
  extend ActiveSupport::Concern
  class_methods do
    def ai_feature(key) = Ai::Owners.register(key, self)
    # def from_ai_job(ids:, **args)  rebuilds the owner; job arguments are ids, never records
  end
  # def ai_generation           → the generation (or judgement) for the owner's remaining items
  # def ai_cancelled?           → true when the user cancelled (section 12); default false
  # def apply_ai(result)        → writes through the domain (enrich_attribute, broadcast); returns a count
  # def ai_finished(count)      → once, after the last batch: RuleRun, completion hook
  # def ai_failed(error)        → once, when the job gives up: RuleRun, domain status
end

# app/models/family/auto_categorizer.rb (domain) — the owner of :categorize
class Family::AutoCategorizer
  include Ai::Owner
  ai_feature :categorize

  def self.from_ai_job(ids:, family_id:, rule_run_id: nil)
    new(Family.find(family_id), transaction_ids: ids, rule_run: RuleRun.find_by(id: rule_run_id))
  end

  def ai_generation
    Ai::Generations::CategorizeTransactions.new(transactions: categorizable(@transaction_ids), categories: family.categories)
  end

  def apply_ai(result) = apply_categorizations(result.value[:categorizations], route: result.route)  # enrich_attribute source: "ai"; withhold? as today
  def ai_finished(count) = (@rule_run&.complete_job!(modified_count: count); after_ai_applied(@transaction_ids))
  def ai_failed(error)   = @rule_run&.fail_job!(error: error.message, source: "ai", transaction_ids: @transaction_ids)
end

# app/jobs/ai/generation_job.rb — the whole job
class Ai::GenerationJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(arguments.first) }

  def perform(feature, args, applied = 0)
    owner   = Ai::Owners.fetch(feature).from_ai_job(**args)
    result  = owner.ai_generation.call!(batches: 1, cancelled: -> { owner.ai_cancelled? })
    applied += owner.apply_ai(result)
    if result.remaining.any?
      self.class.perform_later(feature, args.merge(ids: result.remaining_ids), applied)   # back of the queue
    else
      owner.ai_finished(applied)
    end
  end
end
```

`Ai::GenerationJob` also calls `owner.ai_failed(error)` when it discards the job or runs out of
retries, so a `RuleRun` never stays pending. The owners: `Family::AutoCategorizer` (`categorize`),
`Family::AutoMerchantDetector` (`detect_merchants`), `ProviderMerchant::Enhancer`
(`enhance_merchants`), `PdfImport` (`extract_pdf`), `RecurringTransaction::Suggestion`
(`bill_setup`, section 12) and `VectorStore` (`embed`). Chat isn't a generation: it has
`AssistantResponseJob` and `Ai::Conversation` (section 8.4).

**Generations run only in AI jobs, never synchronously elsewhere.** Rules are background work, so
a rule action that needs AI queues an `Ai::GenerationJob`, as `auto_categorize` does today; it
never calls a model inside the rule job.

**Provenance of applied results.** When the domain applies an AI result through
`enrich_attribute(..., source: "ai")`, the `DataEnrichment.metadata` records the route (endpoint
and model) and the confidence, as Bayes already records its confidence and settings digest. Each
transaction can then show which model set its category (U4).

**A completion hook.** After a job applies a generation's results, it calls the domain owner's
hook, for example `Family::AutoCategorizer#after_ai_applied(transaction_ids)`. The plumbing only
promises the hook. A rule that should run only after an AI rule is a rule-runner feature built on
it, in its own PR (section 20).

### 8.2 Shadow runs

A shadow run is the same generation or judgement, run on the `shadow_<feature>` route, as an
ordinary queued job in the background lane. Categorization is the only feature that declares one
today, but nothing about it is categorization-specific.

```ruby
class Ai::Generations::CategorizeTransactions < Ai::Generation
  feature :categorize
  prompt  :categorize_transactions
  schema  SCHEMA
  batch   :transactions
  merge   :categorizations, by: :transaction_id
  # item → [value, confidence]; ids, not names, so renamed or duplicate categories still compare
  shadow  compare: ->(value) { value[:categorizations].to_h { [ _1[:transaction_id], [ _1[:category_id], _1[:confidence] ] ] } }
end

class Ai::Judgements::CategorizeTransaction < Ai::Judgement
  feature :categorize
  shadow  compare: ->(decisions) { decisions.to_h { [ _1.transaction_id, [ _1.category_id, _1.confidence ] ] } }
end
```

- **Its own route.** `shadow_categorize` has its own model list. Whether a family's shadow runs
  reach Jev, Anthropic or a second local model is the instance admin's choice, and so is the rate:
  `Setting.ai_shadow_rates`, set beside the `shadow_categorize` route. Shadow runs are an
  operator's experiment, not a household decision. The family's control is its Categories row,
  which covers shadow runs, and its allowed endpoints, which limit where they can send data.
- **Same model allowed.** Nothing requires the shadow to use a different endpoint or model.
  Same-model experiments are first-class:
  - a different prompt: `{ model: gpu/qwen3-8b, prompt: categorize_transactions_trial }` runs
    `app/prompts/categorize_transactions_trial.md` against the live prompt;
  - a different JSON mode: `{ model: gpu/qwen3-8b, json_mode: json_object }` against the
    endpoint's `strict`;
  - a different reasoning effort: `{ model: openai/gpt-5.4-nano, reasoning_effort: high }`
    against the live `low`;
  - the identical route twice, which measures how repeatable the model is.
- **Asynchronous.** The job gets the input actually sent and the primary output as arguments. It
  can't re-query, because the primary's answers are already applied and locked. It never holds
  the AI thread for the primary job (drift bug 8).
- **Same pipeline, never applied.** The job emits the normal event with `shadow: true`, so usage,
  Langfuse and the debug log need no extra code, and the usage page shows shadow spend separately.
  Only `ComparisonSubscriber` sees the result. It writes one `Ai::Comparison` row per item:
  `feature, family, subject (polymorphic: the transaction), primary_route, shadow_route,
  primary_value, shadow_value, primary_confidence, shadow_confidence, agreed`. Values are ids, and
  confidence is null when a model gives none. Each route is stored as jsonb with its endpoint,
  model and any overrides, so a comparison reads "strict vs json_object" or "default prompt vs
  trial prompt", not the same route twice. `CategorizationComparison` rows migrate into
  `Ai::Comparison`.
- **Never written to the transaction.** Shadow results live only in `Ai::Comparison`, which feeds
  the agreement figures on the health page (section 13). They're never written to
  `DataEnrichment` or to `transactions.extra`, which holds provider namespaces written by bank
  sync (`Account::ProviderImportAdapter`) and a few app markers such as goal pledges.
- **Never for conversations.** A chat turn can run write tools, so `Ai::Conversation` can't
  declare `shadow`.

### 8.3 Prompts

**One home.** Every prompt Sure writes lives in `app/prompts/`: the generation prompts (moved from
the provider workers' heredocs, which are deleted), the chat system prompt (from
`Assistant::Configurable`), and the chat messages Sure drafts for a user: the "Dig in with AI"
prefill (from i18n) and the bills AI review (`Bills::AiReviewsController::REVIEW_PROMPT`). i18n
holds UI text only, never prompt text. Tool descriptions stay in the tool classes. Plain
`%{placeholder}` interpolation, no ERB.

**Names.** A prompt file is `app/prompts/<name>.md`. The default for a feature is
`<key>.md` (`categorize_transactions.md`). Any other name is just a name: a shorter prompt for a
small model, or a trial prompt for a shadow run, is a file the route entry names
(`prompt: categorize_transactions_short`). The only naming convention is the locale suffix.

**Which prompt runs.** The first that applies:

1. the family's override, for keys a family can override (below);
2. the route entry's `prompt:`, set by the instance admin;
3. the feature's default, `<key>.md`.

**Locale.** For whichever file was chosen in steps 2–3, Sure looks for `<name>.<locale>.md` and
falls back to `<name>.md`. The locale is the user's when a user started the work (chat, bill
setup, PDF import, the dig-in prefill), otherwise the family's (background work). For a German
user, `categorize_transactions.de.md` is used if it exists, otherwise `categorize_transactions.md`.
Translations are optional files; today only the dig-in prefill has one
(`insight_dig_in.de.md`, moved from `de.yml`). A family override isn't localised: the family
wrote it in the language it wants.

**Validation.** A route entry that names a prompt whose `<name>.md` doesn't exist fails
validation in the UI and stops the boot for `AI_CONFIG`; it's never silently replaced.
`Ai::Comparison`'s route jsonb records the prompt that actually ran (family override, named file
or default, and the locale file), so a shadow comparison shows which prompts were compared.

**Overrides.** Moving a prompt into a file doesn't make it overridable. Only the keys below can be
overridden by a family.
- `Family::AiPromptable` stays as the storage layer, with one override per feature instead of one
  per provider:

| Old key | New key |
|---|---|
| `categorizer_openai`, `categorizer_anthropic` | `categorize_transactions` |
| `merchant_openai`, `merchant_anthropic` | `detect_merchants` |
| `chat_system` | `chat_system` |
| `insight_dig_in` | `insight_dig_in` (a chat prefill, not a generation prompt) |

- Data migration: keep the override that matches the family's current provider. If both exist and
  differ, keep the active one, record the other in `DebugLogEntry` and show it once on the prompts
  page.
- Features with no override today (bill setup, enhance merchants, PDF, the bills AI review) get a
  prompt file but stay without an override.

### 8.4 `Ai::Conversation` — chat

Chat isn't a generation: it streams, calls tools in rounds and continues a history. It has one
class, called by `AssistantResponseJob` on `ai_interactive`:

```ruby
# app/models/ai/conversation.rb
class Ai::Conversation
  def initialize(chat:, user:, tools:)   # tools: Assistant.function_classes(user), as today
    @chat, @user, @tools = chat, user, tools
  end

  # Streams one assistant turn into the message; returns Ai::Result.
  def respond(message, cancelled: -> { message.reload.cancelled? })
    # 1. Ai::Router#resolve(:chat): the family's chat mode picks model or agent routes (section 5.3).
    # 2. Ai::Sequencer.run(plan) on the interactive lane; failover only here, before the first chunk.
    # 3. History::for(@chat, route:): previous_response_id when the last turn ran on this endpoint
    #    and it has responses_api, otherwise messages rebuilt and trimmed to the model's budget.
    # 4. Rounds: route.transport.converse(request) { |chunk| message.append_text!(chunk) }; tool calls
    #    go to Assistant::FunctionToolCaller and start the next round, at most Setting.ai_max_tool_rounds
    #    (the last without tools), within Setting.ai_response_timeout for the whole turn (section 5.5).
    # 5. Instrument converse.ai and store the serving route on the message.
  end
end
```

What happens to today's chat classes in PR 3:

| Today | After PR 3 |
|---|---|
| `Assistant.for_chat`, `config_for`, `available_types`, `implementation_for` | Deleted. `AssistantResponseJob` calls `Ai::Conversation`. `Assistant.function_classes` stays: it lists chat's tools, with today's preview and guest filtering |
| `Assistant::Base`, `Assistant::Builtin`, `Assistant::Provided` | Deleted; their work is `Ai::Conversation#respond` |
| `Assistant::Responder` | Its round loop and final no-tools round move into `respond`; deleted |
| `Assistant::FunctionToolCaller` | Stays: it runs tools against the family's data, which is domain work |
| `Assistant::HistoryTrimmer`, `TokenBudget`, `TokenEstimator` | Move to `Ai::Conversation::History`. The budget comes from the model's `context_window` minus `max_output_tokens`, so `LLM_MAX_HISTORY_TOKENS` and `LLM_SYSTEM_PROMPT_RESERVE` go |
| `Assistant::Configurable` | The system prompt text moves to `app/prompts/chat_system.md`; the values it fills in (date, currency, accounts) stay in the domain as `Chat#prompt_locals` |
| `Assistant::External`, `Assistant::External::Client` | Deleted; the `compatible` transport's agent mode |
| `Assistant::External::ModelCatalog` | Deleted; the agent's model is the agent endpoint's model row |
| `Provider::Openai` and `Provider::Anthropic` chat methods and stream parsers | Deleted; `converse` on the transports |

- **Streaming** appends to the `AssistantMessage` and broadcasts through the existing message
  broadcasts, so the chat views don't change.
- **`chats.latest_assistant_response_id`** stays on `chats`. It's sent only when the previous
  assistant message's route has the same endpoint and that endpoint has `responses_api`;
  otherwise it's cleared and the history is rebuilt from `messages`.
- **The route chooses the model.** The chat form's hidden `ai_model` field and the API's `model`
  parameter are accepted and ignored. `messages.ai_model` records the model that served the turn,
  which the API already returns (section 18).
- **Allowed emails.** An agent endpoint whose `agent_settings` lists allowed emails serves only
  those users; the router skips it for anyone else (section 5.3), as
  `Assistant::External.available_for?` does today.

## 9. `Ai::Result` and `Ai::Error`

```ruby
Ai::Result = Data.define(:value, :error, :availability, :usage, :route, :failed_over_from, :remaining, :correlation_id) do
  def self.unavailable(availability) = new(value: nil, error: nil, availability:, usage: nil, route: nil,
                                           failed_over_from: nil, remaining: [], correlation_id: nil)
  def success?      = error.nil? && availability.nil?
  def unavailable?  = !availability.nil?
  def cancelled?    = error.is_a?(Ai::Error::Cancelled)
  def remaining_ids = remaining.map(&:id)   # items a batched call didn't reach (section 8.1)
end

module Ai::Error
  Base           = Class.new(StandardError)
  class Unavailable < Base           # call! on a feature that resolves unavailable
    attr_reader :reason              # the same reason Ai::Availability gives (section 16)
    def initialize(reason) = super("AI unavailable: #{@reason = reason}")
  end
  Cancelled      = Class.new(Base)
  Busy           = Class.new(Base)   # background job found its slot taken; re-enqueued, not an error
  Unreachable    = Class.new(Base)   # connection refused / DNS; failover + down mark
  Timeout        = Class.new(Base)   # failover + down mark
  RateLimited    = Class.new(Base)   # 429; failover + key mark, retryable
  Upstream       = Class.new(Base)   # 5xx; failover + down mark
  Unauthorized   = Class.new(Base)   # 401/403; failover + key mark, not retryable (the key is wrong)
  ContextTooLong = Class.new(Base)   # 400 saying the input is too long; escalation
  InvalidOutput  = Class.new(Base)   # parse / schema failure after the transport's fallbacks; escalation
  Refused        = Class.new(Base)   # any other 4xx; not retried anywhere
end
```

Transports map SDK and Faraday errors into this taxonomy, including each provider's wording for a
context-length 400. `Ai::Error` replaces `Provider::Error` and `Provider::Response`.
`Ai::GenerationJob` calls `call!` and uses
`retry_on Ai::Error::RateLimited, Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::Unreachable, wait: :polynomially_longer`
and `discard_on Ai::Error::Unavailable, Ai::Error::Refused, Ai::Error::Unauthorized, Ai::Error::ContextTooLong, Ai::Error::InvalidOutput, Ai::Error::Cancelled`.
A job whose feature became unavailable after it was queued (chat turned off, consent withdrawn)
is discarded, and its reason is logged.
These job-level policies apply after the in-call failover or escalation (section 5.4) has
already been tried. `Ai::Error::Busy` is handled separately: the job re-enqueues itself after 5
to 15 seconds (random), with no attempt limit, because a busy slot isn't a failure. Feature code
has no `rescue` blocks of its own. Health probe failure codes map from the same classes.

The plumbing doesn't promise idempotency. A retry may call the model again with the same input,
and applying a result safely more than once is the calling workflow's job (for categorization,
enrichment locks already do this).

## 10. Instrumentation: Langfuse, usage/cost, debug log

These are subscribers to one event:

```ruby
# config/initializers/ai_instrumentation.rb
ActiveSupport::Notifications.subscribe(/\.ai\z/, Ai::Instrumentation::UsageSubscriber.new)       # LlmUsage row, success AND failure (fixes drift bug 2)
ActiveSupport::Notifications.subscribe(/\.ai\z/, Ai::Instrumentation::LangfuseSubscriber.new)    # trace + generation; no-op when Langfuse unset
ActiveSupport::Notifications.subscribe(/\.ai\z/, Ai::Instrumentation::DebugLogSubscriber.new)    # DebugLogEntry on failure / unavailable / failover
ActiveSupport::Notifications.subscribe(/\A(generate|judge)\.ai\z/, Ai::Instrumentation::ComparisonSubscriber.new) # shadow: true only
```

- Every event carries a **correlation id** (`sync_id`, `rule_run_id`, `chat_id`, `pdf_import_id`),
  written to `llm_usages.metadata` and Langfuse. It answers "did AI run last night, and for what?".
- `llm_usages.operation` values become feature keys, so usage sums per feature. A data migration
  rewrites existing rows.
- The table keeps its columns: `provider` holds the endpoint's name, `model` the model's name,
  and `estimated_cost` the cost from the model's prices. `metadata` gains `route` (endpoint,
  model, overrides, prompt), `error_class`, `failed_over_from` and `escalated_from`, which the
  health page's rates read (section 13).
- Transports normalise usage once into
  `Ai::Usage = Data.define(:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :cost)`.
  Cost comes from the model's prices, so `LlmUsage.calculate_cost` and `.infer_provider` go away.
- Agent calls report no tokens. They're still recorded, with zero cost, so the usage page shows
  that they happened.
- Cancelled calls are recorded too, because a request that isn't streamed still costs money.
- Secret redaction lives in one helper that every subscriber uses. What Langfuse traces contain
  doesn't change.

## 11. `Ai::Sequencer` — interactive work first

The sequencer decides when a job's LLM call runs. It has three lanes, one slot per local host and
two rules. There's no mode setting.

**Three lanes, three queues.** Each feature's lane is fixed in the routing table, so adding a
feature never adds a queue. The `ai` capsule runs the queues in strict order:

| Lane | Queue | Features |
|---|---|---|
| Interactive | `ai_interactive` | `chat`, `bill_setup`, `search_documents` |
| Prompt | `ai_prompt` | `extract_pdf`, `embed` |
| Background | `ai_background` | `categorize`, `shadow_categorize`, `detect_merchants`, `enhance_merchants`, and probes |

They replace `ai_high_priority` and `ai_low_priority`. For one release the capsule also drains the
old queues, and the old job classes stay as shims that enqueue `Ai::GenerationJob`.

**Concurrency comes from threads and hosts, not a setting.**

- **Calls at once, at most:** the AI threads across all workers (workers × `RAILS_AI_MAX_THREADS`).
- **Each local host takes one call at a time.** Local endpoints on the same host share one slot,
  whatever their ports. A chat server on `http://llm.lan:8080` and an embedding server on
  `http://llm.lan:8081` usually share the same CPU or GPU, so a call to one slows the other; with
  one slot, they take turns, chat first.
- **Cloud endpoints have no slot.** Providers handle concurrency themselves, and 429s are retried
  with backoff.

| Setup | Behaviour |
|---|---|
| One worker, `RAILS_AI_MAX_THREADS=1` (the default) | One call at a time overall, as today; chat first |
| `RAILS_AI_MAX_THREADS=3`, chat and embedding on one local host, plus a cloud endpoint | The local host takes one call at a time, chat before embedding; calls to features routed to the cloud run alongside. A feature whose route starts with the local host waits for it rather than moving to the cloud (no overflow) |
| Cloud only | No limit beyond the threads |

**Keyed by host.** The slot key is the endpoint's host, without port, path or scheme, and the
`location` already on every endpoint decides whether it has one. Two endpoint rows on one host
(for example to compare JSON modes, or the same server added twice by accident) share the slot.
The cost: two GPUs in one machine on different ports are serialised too. To run them in parallel,
give the endpoints different host names (a second DNS name for the same machine).

**Thread counts stay as they are today.** `config/sidekiq.yml` keeps its sizing: the default
capsule gets `RAILS_MAX_THREADS - RAILS_AI_MAX_THREADS` and the `ai` capsule gets
`RAILS_AI_MAX_THREADS` (default 1). `RAILS_MAX_THREADS` stays the worker's total and its DB pool,
so `database.yml` doesn't change. These are per-process tuning, so they stay in ENV; `Sure/NoAiEnv`
doesn't flag them. Every worker runs the `ai` capsule, as today.

- **At the default of 1 thread, the slots make no difference.** One thread makes one call at a
  time, which is today's safe behaviour, and chat still goes first because it's the next job taken
  from the strict-order queues when the current batch ends. Parallel calls (cloud, or local hosts
  side by side) need `RAILS_AI_MAX_THREADS` of 2 or more.
- **`RAILS_AI_MAX_THREADS` must stay below `RAILS_MAX_THREADS`**, or the default capsule has no
  threads and Sidekiq won't start, as today.

**Rule 1: interactive and prompt jobs wait for a slot, in lane order.** A chat job that finds its
local host busy waits in the process and takes the slot as soon as it's released, ahead of any
waiting prompt job. Each host has one `Monitor` with its waiters ordered by lane, then by arrival.
A waiting chat job has no timeout of its own: the chat watchdog (`Setting.ai_response_timeout`)
already ends a turn that waits too long, and cancelling it removes the waiter.

**Rule 2: background jobs never wait.** If the first route that isn't down is on a local host
whose slot is taken, the job raises `Ai::Error::Busy`, re-enqueues itself after 5 to 15 seconds
(random) and frees its thread. With more than one
AI thread, background work therefore can't fill them all, and a free thread is there for the next
chat job.

```ruby
# app/models/ai/sequencer.rb
module Ai::Sequencer
  # Yields the first route in the plan that isn't down. A cloud route runs at once. A local route
  # needs its host's slot: interactive and prompt callers wait for it in lane order; background
  # callers get Ai::Error::Busy. A busy host never sends the call to a later route.
  def self.run(plan, &block)
    up    = plan.routes.find { !Ai::Router.down?(_1) } or raise Ai::Error::Unreachable
    route = slots.acquire(up, lane: plan.lane)
    yield route
  ensure
    slots.release(route) if route
  end

  # One in-process slot per local host; cloud routes are never held.
  def self.slots = @slots ||= Slots.new
end
```

**Nested calls run under the parent's slot.** A chat tool can call AI inside a turn, for example
`search_family_files` embedding its query on the same local host. If the thread already holds a
slot, the sequencer doesn't take another, so a chat turn can't deadlock waiting for itself. The
nested call is recorded with the parent's correlation id.

**Small batches.** `Ai::GenerationJob` runs one batch and enqueues the remainder at the back of
its queue. A chat job enqueued mid-run waits for the current batch, not the whole run, and
families' batches interleave, so one family's large import takes turns with other families' work.

**Several workers.** Slots live in each process, so with two workers a local host can get one call
from each. That's visible, not silent: the health page shows the AI threads per worker (from
`Sidekiq::ProcessSet`) and, for each local host, which job holds its slot in each worker.

**No LLM call on a web thread.** Smart-fill and smart-configure render a skeleton, enqueue a job
on `ai_interactive`, and receive the result as a Turbo Stream broadcast, the same pattern as
`Chat#broadcast_pending_status`. Non-PDF embedding in `ImportsController` and health probes become
jobs too.

**Visible waiting.** Each slot records its holder and waiters in `Rails.cache`
(`ai/slots/<host>`: worker, job id, feature, lane, since). The chat watchdog (`Chat.response_timeout`)
and `BackgroundJobHealth` read it, so the UI can say "waiting for the model; 1 task ahead" instead
of timing out silently, and the health page shows the same data.

The sequencer replaces #4444 (holding back AI jobs while someone types a chat message).

## 12. Cancellation

Users can cancel AI work they started: a chat response, a smart-configure or smart-fill request,
and a PDF import.

- The record that started the work holds the status, so the plumbing takes a `cancelled:`
  callable, for example `-> { pdf_import.reload.cancelled? }`. There's no separate token to
  expire. Today none of these records can say "cancelled", so PR 4 adds it:

  | Work | Record | Change |
  |---|---|---|
  | Chat response | `AssistantMessage` | `cancelled` added to `Message`'s `status` enum (a string column, no migration) |
  | PDF import | `PdfImport` | `cancelled` added to `Import`'s `status` enum (a string column, no migration) |
  | Smart-fill, smart-configure | `RecurringTransaction::Suggestion`, new | A table: `recurring_transaction_id`, `family_id`, `mode` (`fill` or `configure`), `status` (`pending`, `complete`, `failed`, `cancelled`), `result` (jsonb). The controller creates one and enqueues the job; it's the `bill_setup` owner, and its `apply_ai` stores the result and broadcasts it, so a reload still shows it |

  Each owner's `ai_cancelled?` reads its own status.
- The plumbing checks it before taking a sequencer slot, between batches, and on every streamed
  chunk. A cancelled conversation stops reading the stream and closes the connection. A request
  that isn't streamed can't be aborted once sent, so its result is discarded when it returns and
  its usage is still recorded. The UI says "Stopped. The model may still finish this request."
- A cancelled call returns `Ai::Result` with `Ai::Error::Cancelled`, which jobs discard.
- Cancelling is a `DELETE` on the resource that started the work (section 15).

## 13. Health checks

- **Probes run per model**, for every model that appears in any route. `Ai::ProbeJob` runs on
  `ai_background` through `route.transport.probe(model)`, so a probe exercises the same client,
  headers, timeout and proxy as production. It checks the declared capabilities: tool calling,
  structured output, vision and embedding.
- `AiHealth::Probe` keeps its caching, redaction, debug logging and `confirming_tools_refusal`
  logic, but stops building its own clients.
- **Probes use the endpoint's timeout.** A separate short probe timeout made sense while probes
  blocked a web thread. As jobs they use `timeout_seconds` like production calls, so a slow local
  server (a CPU host loading a model, at 300 seconds) isn't marked down by a probe that gave up
  after 5.
- **Probes queue like other background work.** On a busy local host a probe re-enqueues
  (Rule 2), so that host's result can be minutes old while it serves chat. The page shows each
  result's age.
- **The health page** (`settings/ai/health`) shows, per endpoint and model: up or down, latency,
  declared and confirmed capabilities, and any down mark. Per model and feature, it shows the
  invalid-output rate and how often calls escalated past it ("qwen3-3b: 30% escalated for
  categorize"), so an admin can reorder the route list; nothing marks a model as weak
  automatically. Both rates come from `llm_usages`: the usage subscriber writes `error_class`,
  `failed_over_from` and `escalated_from` into `metadata` on every call (section 10). Where shadow runs exist, it also shows agreement by confidence band from
  `Ai::Comparison`, which tells an admin whether a model's confidence can be trusted
  (`calibrated_confidence`, section 6).
- **Operations on the same page:** lane state (queue depths, and the job holding each local
  host's slot in each worker), the AI threads per worker so an operator can see how many calls
  can run at once (section 11), where the config came from (UI, `AI_CONFIG` or the deprecated ENV)
  with a warning when workers loaded different digests. "Re-probe" enqueues probe jobs; the web
  never calls a model.
- **Context window check.** Presets for servers that report their context name it with a
  `context_probe:` field. The probe reads the server's figure, and the health page warns when a
  model's `context_window` is larger ("qwen3-8b declares 32768, the server runs 8192"), because
  batches sized for the declared window would be truncated. Nothing is changed automatically.
  - `llama_cpp_props`: `GET /props`, `default_generation_settings.n_ctx`, the context of one slot
    (the server's total divided by its parallel slots), which is what one request gets.
  - `ollama_show`: `POST /api/show`, `model_info["<architecture>.context_length"]`, the model's
    maximum. Ollama doesn't report the context it actually loads, so this check only catches a
    declared window above the model's maximum.
- **Copy diagnostics.** A button on the health page copies a redacted text block for bug reports:
  Sure version, config source and digest, each endpoint's preset, protocol and location, its
  models with declared and confirmed capabilities, the routes, down marks, lane state, AI threads
  per worker, and the last error class and time per feature. Keys, headers, agent settings,
  family names, prompts and transaction text are never included, and local host names are
  replaced by labels (`local-1`, `local-2`). It's built in the web from stored data, with no
  model call.
- **The AI-cache reset stops.** Changing a model no longer clears every family's AI cache.
  AI-set values stay until AI locks are redesigned.

## 14. MCP's AI tools and Pipelock

**The MCP server itself is a separate proposal**: its renames, a tool catalog shared with chat,
`read_only?` and scopes, and a family switch. This section covers only what the AI plumbing needs
from it. MCP keeps working as today throughout, `mcp_only` families included: today's MCP never
reads `assistant_type`.

**AI-dependent tools run through the AI pipeline.** Two MCP tools call AI:
`import_bank_statement` (`extract_pdf`) and `search_family_files` (`search_documents`: pgvector and
Qdrant embed the query, and the OpenAI adapter calls the vector store's search). Both make that
call inside the MCP web request today. Their AI work moves into the `ai` capsule like every other
AI call, in PR 4, with the other web-thread calls (section 19).

- An AI-dependent tool is listed only when `Ai.available?(feature)` is true for the token's user,
  so a client never sees a tool that can't work by setup. This replaces today's check in PR 2.
- `search_family_files` runs as an `Ai::ToolJob` on `ai_interactive`. The MCP request waits for
  the result for up to 30 seconds, then returns it, or returns "busy, try again". The web thread
  waits; it never calls a model. The handoff is `Rails.cache`: the job writes its result to
  `ai/tool_results/<job id>` (expiring after 2 minutes), and the request polls that key every
  250 ms. `ActiveSupport::Notifications` can't be used, because it doesn't cross processes.
- `import_bank_statement` takes minutes, so over MCP it returns a pending import at once and
  queues an `Ai::GenerationJob(:extract_pdf)`; a new read-only tool, `get_import_status`, reports
  progress and the result. Chat keeps calling it as it does today, inside the chat job.

**Pipelock.** The CI scan stays as it is. At runtime, `Ai::Transport::Http` is the only place that
builds AI HTTP clients, so it's the only place that has to honour the proxy (section 7). The proxy
change can cause new blocks on hand-built Pipelock setups that relied on Anthropic going direct;
the compose example and the Helm chart already set both proxy variables.

## 15. Controllers (RESTful, thin)

AI settings move out of the 514-line `Settings::HostingsController` into one resource per
concern, under `/settings/ai`:

```ruby
# config/routes.rb
namespace :settings do
  namespace :ai do
    # family-scoped: family admins
    resource  :features,        only: %i[show update]       # the AI features page: chat mode, each feature on/off with its manifest;
                                                            # from PR 8 also the endpoints the family allows with its own keys,
                                                            # and a switch per member
    resource  :categorization,  only: %i[show update]       # the categorization workflow: confidence threshold
    resource  :prompts,         only: %i[show update]       # was settings/ai_prompts; linked as "Advanced" from the AI features page
    resource  :usage,           only: :show                 # was settings/llm_usage

    # instance-wide: User#manages_instance_settings?; read-only unless the config source is the UI
    resources :endpoints do                                 # new = pick a preset
      resources :models, except: %i[index show]
    end
    resources :routes,      only: %i[index update], param: :feature   # ordered model list per feature, and shadow rates
    resource  :health,      only: %i[show create]           # create = enqueue probes
  end
end

# cancellation: DELETE on the resource that started the work
resources :chats do
  resource :response, only: :destroy, module: :chats
end
resource :smart_configuration, only: %i[show create destroy], module: :bills
resources :pdf_imports do
  resource :ai_processing, only: :destroy, module: :pdf_imports
end
```

```ruby
class Settings::Ai::BaseController < ApplicationController
  layout "settings"
  before_action :require_admin!

  # Instance-wide resources opt in. Writes are refused while a config file or the deprecated ENV
  # owns the configuration (section 4.1); the web learns that from the stored source.
  def self.instance_wide
    before_action -> { redirect_to settings_ai_features_path, alert: t("settings.ai.not_authorized") unless Current.user.manages_instance_settings? }
    before_action -> { head :forbidden unless Ai::Config.current.source == :ui }, only: %i[create update destroy]
  end
end

class Settings::Ai::EndpointsController < Settings::Ai::BaseController
  instance_wide

  def create
    @endpoint = AiEndpoint.from_preset(params[:preset], endpoint_params)
    if @endpoint.save
      redirect_to settings_ai_endpoint_path(@endpoint), notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end
end
```

The validation that's inline in `HostingsController#update` today moves into the models' own
validations. The `"********"` masked-secret convention stays for `api_key`. Old routes redirect
to the new ones for one release.

Feature controllers get one AI guard, and it answers only "is this AI feature available?":

```ruby
# app/controllers/concerns/ai_feature_guard.rb
module AiFeatureGuard
  extend ActiveSupport::Concern

  class_methods do
    def requires_ai(feature, **options)
      before_action(**options) { require_ai!(feature) }
    end
  end

  private
    def require_ai!(feature)
      availability = Ai.availability(feature, family: Current.family, user: Current.user)
      return if availability.available?

      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: availability.message_for(Current.user) }
        format.json { render json: { error: "ai_unavailable", reason: availability.reason }, status: :forbidden }
      end
    end
end

class Bills::SmartConfigurationsController < ApplicationController
  include AiFeatureGuard, RecurringFeatureGuardable
  requires_ai :bill_setup
  def show    # dialog shell + turbo-stream target; result and serving model arrive by broadcast
  def create  # creates a RecurringTransaction::Suggestion and enqueues its Ai::GenerationJob(:bill_setup)
  def destroy # marks the suggestion cancelled
end
```

`ChatsController`, `MessagesController`, `Api::V1::{Chats,Messages}Controller`, `InsightsController`
("Dig in with AI"), `Bills::AiReviewsController` and `FamilyMerchantsController` all switch to
`requires_ai`. "Dig in with AI" and the bills AI review use `requires_ai :chat`.

- **Separate guards, one concern each.** `requires_ai` replaces `RequiresAiConsent`,
  `bills_one_shot_ai_available?`, the `User#ai_enabled?` checks in controllers and
  `Api::V1::BaseController#require_ai_enabled`. Domain gates stay with their domain and run first:
  `ensure_recurring_enabled` stays in `RecurringFeatureGuardable`, so when bills are off the AI
  question doesn't arise.
- **Preview features and the guest role aren't controller guards.** They filter tools, not
  access, so they stay in `Assistant.function_classes`, as today. A guest can still chat, without
  the family-config tools.
- **The JSON response** keeps the status the mobile app gets today from `require_ai_enabled` and
  adds a `reason` field, which doesn't break the app.

## 16. Working without AI

- The router always returns an `Availability` with a reason: `:not_configured`,
  `:capability_missing`, `:endpoint_not_allowed`, `:no_family_consent`, `:consent_outdated`
  (the feature now sends more than the family agreed to), `:user_disabled`, `:blocked_by_admin`
  (a family admin turned AI off for this member) or `:key_missing` (every
  candidate endpoint needs the family's own key, and it has none). `:no_family_consent` and
  `:consent_outdated` first appear with PR 6; `:endpoint_not_allowed`, `:key_missing` and
  `:blocked_by_admin` with PR 8. Consent is per feature, so one feature can be unavailable while another works.
- One view component, `Ai::AffordanceComponent.new(feature:)`, renders the AI button when the
  feature is available. Otherwise it renders nothing, or a quiet hint shown only to someone who
  can act on it: "Turn on AI in your preferences" for the user, or "Turn on <feature> on the
  AI features page" for a family admin. Views stop writing `if @llm_available`.
- Features degrade instead of disappearing because domain models own the fallback (Bayes before AI
  for categorization). The AI layer doesn't know these fallbacks exist.
- **System test `NoAiSmokeTest`**: with no AI endpoints, visit dashboard, transactions, bills,
  merchants, rules, insights, imports and settings, and assert there are no AI affordances, no
  errors and no `DebugLogEntry` rows of level `error`. The MCP server still answers.

## 17. Invariants as executable checks

Agents fix failing checks reliably, so each rule here is a test or a cop rather than prose.

**Custom RuboCop cops** (`lib/rubocop/cop/sure/`):

| Cop | Flags | Allowed in |
|---|---|---|
| `Sure/NoAiEnv` | `ENV` reads of AI-looking names (section 4.7) | `app/models/ai/config_file.rb`, and `app/models/ai/legacy_env_config.rb` until the deprecated variables are removed |
| `Sure/AiClientConstruction` | `OpenAI::Client.new`, `Anthropic::Client.new`, `Faraday.new` with AI hosts | `app/models/ai/transport/**` |
| `Sure/AiOutsideCapsule` | `Ai::Sequencer.outside_capsule` | `lib/eval/**` |
| `Sure/NoPromptHeredoc` | heredocs over 10 lines inside `app/models/ai/**` and `app/controllers/**` | — |

**Architecture tests** (`test/architecture/`):

- `ai_routing_matrix_test.rb`: every generation, judgement and conversation declares a feature
  that exists in `Ai::Routes::MATRIX`; every row has a lane, a consent level and a non-empty
  `sends:` list whose entries have i18n descriptions; every feature has a test file. Every key is
  snake_case and contains no provider or model name, and every `shadow_` key has a matching
  feature. Every `consent_as:` names a feature with the same consent level, and there are
  exactly six consent keys, each with an i18n row label.
- `ai_presets_test.rb`: every preset file loads, uses a known protocol and known capabilities,
  and has a fixture. `config/ai.example.yml` loads.
- `ai_config_test.rb`: the web and a Sidekiq process build the same `Ai::Config` snapshot from the
  same rows. A web process never loads `AI_CONFIG` or the deprecated ENV. For each of PR #4440's
  nine configurations, the deprecated ENV path produces the routes today's code resolves, and
  `ai:export_config` round-trips to the same digest.
- `ai_agreement_test.rb` (PR #4440's E2): across nine configurations plus mixed per-feature
  routes, every entry point gives the same availability answer.
- `ai_local_engines_test.rb`: nothing under `app/models/ai/` references the local engines, and
  those engines don't reference `Ai::`.
- `ai_shadow_test.rb`: every class that declares `shadow` also declares `compare:` and has a
  `shadow_<feature>` row; no `Ai::Conversation` declares `shadow`; only `ComparisonSubscriber`
  receives shadow results.
- `ai_prompts_test.rb`: every `prompt` key has `<key>.md`; every `Family::AiPromptable` key maps
  to a file; every `<name>.<locale>.md` has a base `<name>.md` and an available locale; no locale
  YAML contains prompt text; no orphaned prompt files (a file is used by a key, a preset's default
  route or `config/ai.example.yml`).
- `ai_schemas_test.rb`: every `schema` is valid JSON Schema and OpenAI-strict-compatible, so one
  schema works on every transport.
- `ai_lane_test.rb`: finds AI jobs from the code, not a hand-written list, and checks each one's
  queue and failure policy, and that no job outside `Ai::GenerationJob`, `Ai::ShadowJob`,
  `Ai::ProbeJob`, `Ai::ToolJob` and `AssistantResponseJob` calls `Ai::`. It's the only check on
  queues, so there's no cop for them. There's no cop for the old provider lookups either: PRs 2
  and 3 delete those methods, so a call to one fails anyway.
- `ai_transport_contract_test.rb`: every transport passes one contract suite against recorded
  cassettes: valid JSON, bad-output fixtures (`<think>` tags, fenced JSON, wrong keys), error
  mapping (including each provider's context-length 400 → `ContextTooLong`), usage normalisation,
  proxy resolution, and reasoning effort (sent in both API forms, left out when unset, dropped on
  the 400 retry and kept on the unusable-output retry).
- `ai_escalation_test.rb`: invalid output from the first model escalates once to the next route
  on the same endpoint without a down mark; an unhealthy server fails over to a different server
  and is marked down; two endpoint rows on one server share a down mark, and two local endpoints
  on one host (different ports) share a slot, with chat ahead of embedding; a busy local host
  never sends a call to the next route; cloud routes never wait; a 429 or 401 marks only the key
  that got it; other `Refused` errors aren't retried.
- `ai_family_key_test.rb`: a family's key is used for its calls and the endpoint's key for
  everyone else's; a failing family key fails over to the next route and never retries with the
  endpoint's key; an endpoint with no key of its own is `:key_missing` for a family without one;
  family keys never appear in logs, Langfuse traces, the debug log, API responses or
  `ai:export_config`.
- `ai_feature_guard_test.rb`: every controller action that starts an AI feature declares
  `requires_ai` for it, and `requires_ai` reads nothing but `Ai.availability`.
- `ai_capsule_only_test.rb`: a transport called outside the `ai` capsule raises, including from a
  web request and a rule job.
- `ai_completion_hook_test.rb`: every generation that applies results calls its owner's hook
  once per applied batch.
- `ai_nested_call_test.rb`: a chat turn that calls `search_family_files` completes when the chat
  and embedding servers share one local host's slot, and the nested call is recorded with the
  chat's correlation id.
- `mcp_ai_tools_test.rb`: an AI-dependent MCP tool is listed only when its feature is available
  for the token's user, and no MCP request calls a transport.
- `ai_chat_mode_test.rb`: in external mode every chat entry point (chat page, API, "Dig in with
  AI", bills AI review) resolves to an agent route; in built-in mode none does; with the Chat row
  off (an `mcp_only` family before PR 6) all are unavailable; no other feature ever resolves to an agent endpoint.
- `ai_conversation_bounds_test.rb`: a model that keeps calling tools gets a final round without
  tools after `ai_max_tool_rounds`; a turn that passes `ai_response_timeout` stops and says so.
- `ai_consent_test.rb`: a feature whose `sends:` grows resolves to `:consent_outdated` for a
  family that agreed to the shorter list; one whose list shrinks stays consented; and, from
  PR 8, a member a family admin turned off gets `:blocked_by_admin` for every user-started feature, can't turn
  their own switch back on, and their transactions still reach family-consented background
  features.
- `ai_diagnostics_test.rb`: the copied diagnostics contain no key, header value, agent setting,
  family name, prompt, transaction text or local host name.

**Testing an AI feature** (the helpers land in PR 2, replacing the stubs it and PR 3 delete; PR 6 backs them with table fixtures):

- **Fixtures.** From PR 6, `test/fixtures/ai_endpoints.yml`, `ai_models.yml` and `ai_routes.yml`
  give every test one configured setup (before PR 6 the helpers build the same setup as an
  in-memory `Ai::Config`): a cloud `openai` endpoint (`gpt-4.1-mini`, every LLM capability), a
  local `gpu` endpoint (`qwen3-8b`), an `embed` endpoint, a cloud `jev` endpoint and an `agent`
  endpoint, with every feature routed. Tests for "no AI" use `without_ai`.
- **Helpers** in `test/support/ai_test_helper.rb`:
  - `with_ai_routes(categorize: ["gpu/qwen3-8b", "openai/gpt-4.1-mini"]) { ... }` replaces the
    named features' routes for the block and expires `Ai::Config`;
  - `without_ai { ... }` empties every route, so every feature is `:not_configured`;
  - `stub_ai(:categorize, returns: { categorizations: [...] })` makes the feature's transport
    return that value (or `raises: Ai::Error::Timeout`), records the requests, and still runs
    coercion, instrumentation and the owner, so a test exercises everything but HTTP;
  - `with_ai_capsule { ... }` runs the block as if inside the `ai` capsule, for model tests
    that call a generation directly.
- **Cassettes.** Transport contract tests record with VCR, as today, under
  `test/vcr_cassettes/ai/<preset>/`. The contract suite's live mode is the same tests with VCR
  off, run only by the `ai-live` label with keys from repository secrets.

**CI gates on AI behaviour** (`.github/workflows/`):

- **Recorded evals on every AI change.** A PR that touches `app/prompts/**`, a generation class or
  its `schema`, `Ai::Schema` or `config/ai/presets/**` runs `evals:ci_regression` against
  recorded model responses. That's free and catches parsing, coercion and mapping regressions.
  Recorded responses can't judge a changed prompt, because the model never saw it.
- **Live runs behind a label.** A maintainer adds the `ai-live` label to run, with keys from
  repository secrets:
  - the eval datasets against a live model, with the accuracy change against the last baseline
    posted as a PR comment. This is the gate for prompt changes.
  - the transport contract suite's live mode against each cloud preset that has a secret
    (presets without one are skipped and listed). It's required before merging a transport
    change or an update to an LLM client gem (`ruby_llm` if adopted, `ruby-openai`,
    `anthropic`). Local presets stay on recorded cassettes.

  Today's `llm-evals.yml`, which runs on release tags, becomes the same job.

Each check starts with an explicit, commented allowlist of current violations. The allowlist may
only shrink, which a test also asserts. The last PR empties every allowlist.

## 18. Breaking changes

Any release can carry breaking changes. Each ships with a migration and an upgrade note.

| Change | What breaks | Migration | Upgrade note |
|---|---|---|---|
| AI configuration moves to `ai_endpoints`, `ai_models`, `ai_routes` and `AI_CONFIG` | Nothing at first. The old AI ENV still works, read by the workers as a deprecated config source; the release that stops reading it is named in the upgrade guide. | UI-configured installs: a data migration. ENV-configured installs: `Ai::LegacyEnvConfig` at every AI worker boot (section 4.5). | Deprecation warning in the worker log and on the AI settings pages. Run `bin/rails ai:export_config > ai.yml` and mount it as `AI_CONFIG`, or remove the variables and use the UI. |
| Global token budgets become model columns; Jev's pool size becomes an endpoint column | `LLM_CONTEXT_WINDOW`, `LLM_MAX_RESPONSE_TOKENS`, `LLM_MAX_ITEMS_PER_CALL`, `JEV_CONCURRENCY` | Mapped onto each model, or the Jev endpoint's `parallel_requests`, by the same two paths | — |
| `assistant_type` becomes chat mode; `ASSISTANT_TYPE` and `CATEGORIZATION_PROVIDER` overrides go | `mcp_only`, the family Jev choice | `mcp_only` → chat switched off on the AI features page (MCP is unaffected); the Jev choice of a single-family instance goes into the `categorize` route | Multi-family instances: the admin puts Jev in the route if wanted |
| Two-level consent (PR 6) | Background AI needs the family's consent per feature | Section 6 | Family admins review the AI features page; members get a notice |
| Prompt overrides, one per feature | Overrides stored under provider keys | Section 8.3 | Shown only where an override was dropped |
| Three lane queues | `ai_high_priority`, `ai_low_priority`, custom `sidekiq.yml`, `SidekiqHealth::AI_QUEUES` | The capsule drains the old queues for one release; old job classes are shims | Update a custom `sidekiq.yml` |
| `Ai::GenerationJob` and `Ai::ShadowJob` replace the AI job classes | Jobs queued in Redis | Shims for one release | — |
| `CategorizationComparison` → `Ai::Comparison` | A persisted table | Rows copied | — |
| `llm_usages.operation` values become feature keys | Usage history under old names | Rows rewritten | The usage page sums per feature |
| The `embed` route picks the vector adapter | `VECTOR_STORE_PROVIDER` defaulting from `LLM_PROVIDER` | The deprecated ENV path maps it | Check which adapter `embed` uses |
| Smart-fill and smart-configure become asynchronous | Response shape of `smart_fills#create` and `smart_configurations#show` | System tests for both dialogs land first | The dialog shows progress |
| `AssistantMessage` stores the route that served it | Adds a column the mobile API reads | Additive | — |
| The route chooses the chat model | The API's `model` parameter on chats and messages is accepted and ignored | None | API clients: `model` in the response says which model served the turn |
| Cancel statuses | `cancelled` added to `Import` and `Message` statuses; `RecurringTransaction::Suggestion` added | Additive (string enums) | — |
| The ENV override of the family confidence threshold goes | `CATEGORIZATION_CONFIDENCE_THRESHOLD` | None | Set it on the categorization page |
| The shadow rate moves from the family to the instance | `families.categorization_shadow_rate`, `CATEGORIZATION_SHADOW_RATE` | One family: its rate is copied to `Setting.ai_shadow_rates`; several: 0 | Multi-family instances: the instance admin sets the rate on the routes page |
| Chat history budget comes from the model | `LLM_MAX_HISTORY_TOKENS`, `LLM_SYSTEM_PROMPT_RESERVE` | None | Set the model's `context_window` and `max_output_tokens` instead |
| `/settings/ai/*` replaces `settings/hostings` AI sections, `settings/ai_prompts`, `settings/llm_usage` | Bookmarks | Redirects for one release | — |
| `import_bank_statement` over MCP becomes asynchronous | Clients that expect the import result in the same call | None | Call `get_import_status` with the returned import id |

## 19. Delivery

Seven merged PRs plus one spike branch (PR 1) that isn't merged. The order follows one rule:
**each PR replaces something outright, and nothing is written only to bridge to a later PR.**
Where code isn't replaced yet, it keeps running as it does today, reading the same settings as
the new code, so the two never disagree. That keeps each review to one question ("is this
replacement right?") rather than "is this temporary state safe?". Size is secondary: a PR is as
big as its replacement needs.

Each PR deletes the code it replaces, lands with its own checks, and has a reviewer guide: what
moved, what was deleted, what to read first. PRs are stacked so review can start early, and the
ones that rewrite hot files (`family.rb`, `assistant.rb`, the hostings files, the settings locale
file) land in the week after a release. Each PR moves its `# pipelock:ignore` tags with the lines
they annotate and says so. Each ends with **Still on old code**: what isn't replaced yet.

1. **RubyLLM spike**, judged against the criteria below, timeboxed to one week on the latest
   release of the gem at the start. It covers the three transport calls the criteria need:
   `generate` for `SuggestBillSetup`, one streaming chat turn with one tool (`converse`), and one
   `embed` call. Its result decides how PRs 2 and 3 are
   built. Either way it ends with a short note in `docs/llm-guides/ai-pipeline.md`: adopted or
   not, which criteria failed and what a later attempt would need.
2. **Generations: every AI call except chat.**
   - **Routing:** `Ai::Config`, built in memory in each process by `Ai::LegacyEnvConfig` from
     today's ENV and `Setting` fields with the table in section 4.5; `Ai::Routes`, `Ai::Router`,
     `Ai::Consent` with the user switch, `Ai.available?`, `AiFeatureGuard`, `Family::AiSettings`,
     `Setting.ai_shadow_rates` replacing `families.categorization_shadow_rate`,
     `Sure/NoAiEnv`.
   - **Calls:** the transports' `generate`, `judge`, `embed` and `probe`, `Http`, `Ai::Generation`,
     `Ai::Judgement`, `Ai::Owner`, `Ai::Batch`, `Ai::Result`, `Ai::Error`, the instrumentation
     subscribers with the correlation id, the proxy fix, prompt files with the key collapse,
     reasoning effort on route entries (#3605).
   - **Jobs:** `Ai::GenerationJob` (with small batches) and `Ai::ShadowJob` replace the four AI
     job classes, which stay one release as shims; `Ai::Comparison` replaces
     `CategorizationComparison`. Lanes map onto today's two queues (interactive →
     `ai_high_priority`, prompt and background → `ai_low_priority`) until PR 5.
   - **Features:** `bill_setup`, `categorize` (generation and Jev judgement), `detect_merchants`,
     `enhance_merchants`, `extract_pdf`, `embed` and `search_documents`, each with its owner.
     `AiHealth::Probe` calls `transport.probe`.
   - **Deletes:** the twelve structured-output workers, `Provider::Jev`, the usage recorders, the
     per-worker tracing, `preferred_llm_provider`, `llm_provider_order`,
     `Family#resolved_categorization_provider` and `#shadow_categorization_provider`, the
     non-chat availability checks, their test stubs and `families.categorization_provider` (a
     single-family Jev choice moves into the `categorize` route).
   - **Adds:** the agreement test (chat entry points on its allowlist until PR 3), the transport
     contract test, the AI test helpers (section 17), the recorded-eval CI gate and the `ai-live`
     label.

   `Generation#call` takes the plan's first route that isn't down; PR 5 puts the slot around
   that choice.
   *Still on old code:* chat, through `Assistant`, `Provider::Openai` and `Provider::Anthropic`'s
   chat methods and `Chat.default_model`, reading the same ENV and `Setting` fields. Smart-fill,
   smart-configure, document embedding and the MCP AI tools call their owners on the web thread,
   as today. Configuration is still edited on the hostings page, and the web and the workers
   each build `Ai::Config` from their own ENV, as they resolve settings today, until PR 6.
3. **Chat.** `Ai::Conversation` (section 8.4), `converse` and the agent mode on the transports,
   chat mode (read from today's `assistant_type` until PR 6), today's `mcp_only` rule as one line
   in `Ai::Consent` (section 6), `previous_response_id` on the same
   endpoint, failover at the start of a turn, bounded turns, the serving route on each message,
   and every chat entry point behind `requires_ai :chat` ("Dig in with AI", the bills AI review,
   and #3442 if it merged first). Deletes what remains of `Provider::Openai` and
   `Provider::Anthropic`, `Chat.default_model`, `Assistant::Provided#get_model_provider` and the
   `Assistant::*` classes listed in section 8.4, and empties the agreement test's allowlist. Adds
   the conversation bounds and chat mode tests.
4. **Off the web thread.** Smart-fill and smart-configure through `RecurringTransaction::Suggestion`
   and a Turbo Stream, non-PDF document embedding as a job, `Ai::ProbeJob`, and the MCP tools
   through `Ai::ToolJob` (with its result handoff) and a pending import plus `get_import_status`
   (section 14). Cancellation: the `cancelled` statuses, `ai_cancelled?` on each owner, and the
   checks in the plumbing (section 12). Capsule-only enforcement, now that no AI call is left on a
   web thread. Adds the capsule-only and completion-hook tests.
5. **Sequencer.** The three lane queues replacing `ai_high_priority` and `ai_low_priority` (the
   capsule drains the old two for one release), one slot per local host, Rules 1 and 2, nested
   calls under the parent's slot, and the slot state the chat watchdog reads. Replaces #4444. Adds
   the lane test and the sequencer cases of the escalation test.
6. **Configuration in the database.** The tables (`ai_endpoints`, `ai_models`, `ai_routes`),
   presets, `Ai::ConfigFile` and `AI_CONFIG`, `ai:export_config`, the data migration of
   UI-stored settings, the version stamp, and the source rule. `Ai::Config` now reads the tables,
   and `Ai::LegacyEnvConfig` loads its structure into them as a deprecated source. The instance
   pages (endpoints with presets, models, routes with each entry's overrides: JSON mode, prompt,
   reasoning effort) and the family AI features page replace the
   hostings AI sections. The AI features page has chat mode and each feature's switch and
   manifest: `families.ai_consents`, the consent migration (an `mcp_only` family gets chat
   switched off, and PR 3's `mcp_only` line goes), member emails, `:no_family_consent` and
   `:consent_outdated`. That fixes drift bug 4. `families.chat_mode` (built-in or external) replaces `assistant_type`, which is dropped.
   The test helpers switch to the new fixtures. Adds the config and consent tests.
   *Still on old code:* nothing; from here every process reads the same rows.
7. **Health and settings pages.** The health page (lanes, down marks, AI threads per worker,
   rates, the context window check, "Copy diagnostics"), each row's status on the AI features
   page with the "AI unavailable" banner, the categorization page, and the prompts (behind
   "Advanced") and usage pages moved under `/settings/ai` with redirects. Adds the diagnostics
   test.
8. **Allowed endpoints, own keys and the member switch.** `families.ai_blocked_endpoint_ids`,
   `ai_endpoint_credentials` and `users.ai_allowed`; the AI features page gains its endpoints
   section, with the allow checkbox and the "use our own key" field with a probe on save, and its
   members section. The router gains its endpoint and key lines (section 5.3), with
   `:endpoint_not_allowed` and `:key_missing`, and `Ai::Consent` gains `:blocked_by_admin`. Adds
   `llm_usages.family_key` and the family key test, and extends the consent test with the member
   cases. Needs PR 6.

**RubyLLM spike criteria.** RubyLLM is adopted under `Ai::Transport::*` only if every item holds
or has a small fix. Whatever the result, Sure still owns the router, consent, the JSON-mode policy
and failover.

- Models missing from RubyLLM's registry still work (`assume_model_exists`).
- One URL normaliser handles `/v1` for every compatible server.
- Prompts, outputs and each tool-loop step reach Langfuse.
- Tool loops stay under `Ai::Conversation`'s bounds (section 5.5), not the gem's own loop.
- The default retries and timeout are overridden by the endpoint's settings.
- LM Studio's rejection of strict schemas and the `auto` JSON-mode fallback still work.
- Anthropic models that reject a forced tool still return structured output (#4513).
- `<think>` blocks are stripped.
- Tool calls stream on Ollama, llama.cpp and LM Studio.
- Gemini thought signatures survive gateways.
- Every client honours the resolved proxy.
- Every error maps onto `Ai::Error`.
- The Responses API and vector stores work through it, or the `responses_api` path stays
  hand-written.
- Report lines removed for `bill_setup` against the hand-written version.

If adopted, pin the version and name an owner: the gem has fast major versions and mostly one
maintainer.

**Measure** after PR 5: chat time-to-first-token while background AI work runs, using Sidekiq
queue latency and the model server's queue depth (for llama.cpp, its Prometheus metrics).

**Docs that ship with the work:**

- **Upgrade guide.** One page per release lists its breaking changes and what an operator or
  family admin does about each.
- **Contributor guide.** `docs/llm-guides/ai-pipeline.md`, linked from `AGENTS.md`: add an AI
  feature, add a preset, add a capability, add a feature to consent and the manifest. The
  `Sure/NoAiEnv` message links here.
- **Generated tables, checked in CI**: routing and manifest (from `Ai::Routes::MATRIX`), presets
  and their models (from `config/ai/presets`), jobs and queues (from the code). CI fails when a
  table is stale and names the command that regenerates it.
- **Release notes** for what users see: Enhance merchants appears on Anthropic-only installs;
  chat is hidden when no model in its route can do tools; bill AI depends on its own consent, not
  on chat; turning chat off leaves other features on; Anthropic batches are token-sliced;
  smart-fill and smart-configure are asynchronous; Anthropic goes through the proxy; consent is
  two-level; the "AI unavailable" notice appears; chat says when it failed over or escalated to
  another model; with more than one AI thread, each local model host takes one call at a time,
  chat first; a family can use its own key for a cloud endpoint.

## 20. Not in scope

- Changing any feature's prompts or models.
- The Ruby ML engines' internals, and the classifier settings page.
- Suggestions instead of AI locks, and rule ordering (phases or an enrichment pipeline).
- Rules that run only after an AI rule. The rule runner can add this later as its own PR,
  triggering the dependent rule from the generation completion hook (section 8.1).
- Family-owned endpoints, models and routes (the rest of #3037: a household choosing its own
  endpoint or model), and per-family cost caps. A family's own key for an instance endpoint is in
  scope (section 4.2). Family-owned endpoints would need protection against a family admin
  pointing a base URL at internal services.
- Keeping a member's private accounts out of background AI processing (section 6).
- An `ai_calls` table replacing `llm_usages`.
- What Langfuse traces contain.
- The MCP server: renames, a tool catalog shared with chat, `read_only?` and scopes, and a family
  switch. They're a separate proposal; only MCP's AI tools are here (section 14).
- Product features from PR #4440's user review.
- New providers beyond presets, and model discovery (#3694). They become presets, model columns or
  transport options. Reasoning effort (#3605) is in scope for the `compatible` transport
  (section 4.2); mapping it onto Anthropic's thinking settings is a later transport option.
- Replacing Langfuse, Sidekiq or rails-settings-cached.
