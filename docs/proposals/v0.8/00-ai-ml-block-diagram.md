# Sure: AI / ML block diagram

A one-page orientation for developers new to Sure's AI and ML code: the main blocks, the models they write, and how a request moves through them. It covers only the workflows in [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md), whose `W#` sections give the detail behind each box.

Checked against `main` @ `2250ba801` (2026-10-23). The 10 commits after this folder's reference commit `56105a3b5` don't change any AI path.

## 1. High-level flowchart

```mermaid
flowchart LR
  subgraph Entry["Entry points (Puma web / cron)"]
    WEB["Web controllers<br/>Chats, Messages, Imports,<br/>Settings::Classifiers, FamilyMerchants,<br/>Bills SmartFills/SmartConfigurations"]
    API["Api::V1 Chats/Messages<br/>+ McpController POST /mcp<br/>(Doorkeeper OAuth)"]
    CRON["sidekiq-cron<br/>SyncAllJob, GenerateInsightsJob,<br/>GenerateRecurringOccurrencesJob"]
  end

  subgraph DefaultCap["Sidekiq default capsule: sync, rules, Ruby ML"]
    SYNC["SyncJob<br/>Family::Syncer post-sync (W1)"]
    RULES["ApplyRulesJob / RuleJob / ApplyAllRulesJob<br/>Rule::Runner (W4)"]
    RML["Ruby ML, inline<br/>SimilarMerchantFiller TF-IDF (W5)<br/>BayesCategorizer (W6), BayesEvaluation (W7)"]
    HEUR["Ruby heuristics<br/>RecurringTransaction::Pipeline (W19)<br/>Insight generators (W17)"]
  end

  subgraph AiLane["Sidekiq ai capsule: 1 thread by default, strict order"]
    CHATJOB["ai_high: AssistantResponseJob<br/>Assistant::Builtin / External, Responder (W13/W14)"]
    AIJOBS["ai_low: AutoCategorizeJob, AutoDetectMerchantsJob,<br/>EnhanceProviderMerchantsJob, ProcessPdfJob (W8-W11)"]
  end

  subgraph Assist["Assistant tools"]
    TOOLS["Assistant::Function::*<br/>30 tools, 44 with preview (W16)"]
  end

  subgraph ProvLayer["Provider layer (app/models/provider, vector_store)"]
    REG["Provider::Registry<br/>Openai (ruby-openai), Anthropic (anthropic gem),<br/>Jev (Faraday)"]
    VS["VectorStore adapters<br/>openai / pgvector / qdrant (W12)"]
    OBS["LangfuseTracing, LlmUsage,<br/>DebugLogEntry"]
  end

  subgraph Infra["Infrastructure"]
    PG[("PostgreSQL<br/>(+ pgvector table if enabled)")]
    REDIS[("Redis<br/>Sidekiq, Rails.cache, ActionCable")]
    STORE[("Active Storage<br/>Disk / S3 / GCS")]
  end

  subgraph Ext["External services"]
    LLM[("OpenAI / OpenAI-compatible /<br/>Anthropic")]
    JEV[("Jev (TypeSafe)")]
    EMB[("Embeddings endpoint, Qdrant,<br/>OpenAI vector store")]
    AGENT[("External agent / MCP client")]
  end

  CRON --> SYNC
  WEB -->|"sync, apply rule"| SYNC
  SYNC -->|"post-sync enqueue"| RULES
  SYNC -->|"debounced"| HEUR
  CRON --> HEUR
  RULES --> RML
  RULES -->|"AI rule actions, batches of 25"| AIJOBS
  WEB -->|"UserMessage after_create_commit"| CHATJOB
  API --> CHATJOB
  API -->|"tools/call, sync in request"| TOOLS
  CHATJOB --> TOOLS
  TOOLS -->|"apply_rule"| RULES
  TOOLS --> VS
  WEB -->|"Enhance, PDF upload"| AIJOBS
  WEB -->|"bill smart-fill, sync HTTP"| REG
  CHATJOB --> REG
  AIJOBS --> REG
  AIJOBS --> VS
  REG --> LLM
  REG --> JEV
  REG --> OBS
  VS --> EMB
  VS --> PG
  CHATJOB -->|"external assistant SSE"| AGENT
  AGENT -->|"calls back via MCP"| API
  RML --> PG
  AIJOBS --> PG
  AIJOBS --> STORE
  CHATJOB -.->|"Turbo Streams"| REDIS
```

## 2. Models (erDiagram)

```mermaid
erDiagram
  FAMILY ||--o{ USER : "has_many users"
  FAMILY ||--o{ ACCOUNT : "has_many accounts"
  ACCOUNT ||--o{ ENTRY : "has_many entries"
  ENTRY ||--|| TRANSACTION : "delegated_type entryable"
  TRANSACTION }o--o| CATEGORY : "belongs_to category"
  TRANSACTION }o--o| MERCHANT : "belongs_to merchant"
  FAMILY ||--o{ CATEGORY : "has_many categories"
  FAMILY ||--o{ MERCHANT : "has_many merchants (FamilyMerchant)"
  TRANSACTION ||--o{ DATA_ENRICHMENT : "polymorphic enrichable"

  USER ||--o{ CHAT : "has_many chats"
  CHAT ||--o{ MESSAGE : "has_many messages"
  MESSAGE ||--o{ TOOL_CALL : "has_many tool_calls"

  FAMILY ||--o{ RULE : "has_many rules"
  RULE ||--o{ RULE_CONDITION : "has_many conditions"
  RULE_CONDITION ||--o{ RULE_CONDITION : "sub_conditions"
  RULE ||--o{ RULE_ACTION : "has_many actions"
  RULE ||--o{ RULE_RUN : "has_many rule_runs"

  FAMILY ||--o{ LLM_USAGE : "has_many llm_usages"
  FAMILY ||--o{ CATEGORIZATION_COMPARISON : "has_many"
  CATEGORIZATION_COMPARISON }o--o| TRANSACTION : "categorized_transaction"
  FAMILY ||--o{ IMPORT : "has_many imports (PdfImport STI)"
  FAMILY ||--o{ FAMILY_DOCUMENT : "has_many (VectorSearchable)"
  FAMILY_DOCUMENT ||--o{ VECTOR_STORE_CHUNK : "raw SQL, pgvector only"
  FAMILY ||--o{ INSIGHT : "has_many insights"
  FAMILY ||--o{ DEBUG_LOG_ENTRY : "optional family"

  EVAL_DATASET ||--o{ EVAL_SAMPLE : "has_many samples"
  EVAL_DATASET ||--o{ EVAL_RUN : "has_many runs"
  EVAL_RUN ||--o{ EVAL_RESULT : "has_many results"
  EVAL_SAMPLE ||--o{ EVAL_RESULT : "has_many results"

  FAMILY {
    jsonb bayes_settings "W5-W7 tuning"
    jsonb ai_prompt_overrides "6 prompt keys"
    string categorization_provider "llm or jev"
    string assistant_type "builtin, external, mcp_only"
    string vector_store_id
  }
  TRANSACTION {
    jsonb locked_attributes "category_id / merchant_id locks"
  }
  MERCHANT {
    string type "FamilyMerchant or ProviderMerchant"
    string source "ProviderMerchant: plaid, ai, ..."
  }
  DATA_ENRICHMENT {
    string attribute_name
    jsonb value
    string source "ai, bayes, similar, rule, provider"
    jsonb metadata "Bayes confidence, digest"
  }
  CHAT {
    string latest_assistant_response_id
    jsonb error
  }
  MESSAGE {
    string type "UserMessage or AssistantMessage"
    string ai_model
    string status
  }
  RULE_RUN {
    string status
    int pending_jobs_count "async AI jobs left"
    string execution_type
  }
  LLM_USAGE {
    string provider
    string model
    string operation
    decimal estimated_cost
  }
  CATEGORIZATION_COMPARISON {
    string applied_provider
    string shadow_provider
    boolean agreed
  }
  FAMILY_DOCUMENT {
    string provider_file_id
    string status
  }
```

## 3. Legend

| Symbol | Meaning |
|---|---|
| Rectangle | Rails class or group of classes (controller, job, model, PORO) |
| Cylinder | Datastore or external service |
| Solid arrow | Direct call or job enqueue (the label says which) |
| Dotted arrow | Async broadcast (Turbo Streams over ActionCable) |
| `ai_high` / `ai_low` | Queues on the one-thread `ai` Sidekiq capsule. `ai_high` always runs first, but can't interrupt a running job. |
| `W#` | Workflow section in [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md) |
| `\|\|--o{` (ER) | one-to-many. `}o--o\|` is an optional belongs_to. |

**Request flow**

- **Chat request:** `POST /chats` → `ChatsController` (`RequiresAiConsent`) → `Chat.start!` saves a `UserMessage`, whose `after_create_commit` enqueues `AssistantResponseJob` on `ai_high_priority`. The request returns right away. The job resolves a provider through `Provider::Registry`, runs `Assistant::Responder` (up to 8 tool rounds through `Assistant::Function::*`), and streams text back with `Message` `broadcast_append_to` / `broadcast_update_to`.
- **Background enrichment:** a sync's post-sync step enqueues `ApplyRulesJob` (default capsule). `Rule::Runner` takes a pg advisory lock and runs rules in order. The Merchant matcher (TF-IDF) and Category classifier (Bayes) run inline in Ruby with no network calls. AI rule actions enqueue `AutoCategorizeJob` / `AutoDetectMerchantsJob` in batches on `ai_low_priority`, and each finished job decrements `RuleRun.pending_jobs_count`. Every write goes through `Enrichable#enrich_attribute`, which skips locked attributes and records a `DataEnrichment` row.
- **External AI:** an MCP client calls `POST /mcp` (Doorkeeper token or `MCP_API_TOKEN`). `McpController` runs the same `Assistant::Function` classes **synchronously inside the web request**, with no LLM on Sure's side, except `import_bank_statement`, which calls the LLM from inside that request.
- **Documents:** a PDF upload creates a `PdfImport` and enqueues `ProcessPdfJob` (`ai_low`). The job has the LLM summarize the PDF, extract its transactions and classify it. It also puts the text into the vector store and emails the admin through `PdfImportMailer`. A non-PDF document is embedded synchronously inside the upload request.
- **LLM calls on a web thread:** bill smart-fill/configure, non-PDF document embedding, MCP `import_bank_statement` and the admin AI health probes call the model from a Puma thread instead of the job queue. A slow local model can tie up web threads.

## 4. Evidence and what's inferred

Read directly from `origin/main`: `Gemfile` (`ruby-openai`, `anthropic ~> 1.0`, `sidekiq`, `sidekiq-cron`, `doorkeeper`, `pundit`, `faraday-retry`, `pdf-reader`, `aws-sdk-s3`, `turbo-rails`, `redis`), the model associations above, the schema columns shown, `config/sidekiq.yml` capsules, `config/storage.yml`, `production.rb` (`redis_cache_store`, `ACTIVE_STORAGE_SERVICE`), `config/initializers/langfuse.rb` and the mailer call sites.

**Inferred or simplified (flagged):**

- `FAMILY ||--o{ ACCOUNT` and `ACCOUNT ||--o{ ENTRY`: I didn't grep these two associations. I took them from the `Entry belongs_to :account` side and from Sure's core domain.
- `VECTOR_STORE_CHUNK` isn't an ActiveRecord model. It's the raw-SQL `vector_store_chunks` table that `VectorStore::Pgvector` writes to, keyed by store id and file id. It isn't in `db/schema.rb`, and the adapter checks whether it exists at runtime. The link to `FAMILY_DOCUMENT` is logical, not a foreign key.
- **Redis for ActionCable:** `config/cable.yml` has a `redis` adapter on its third entry. I assumed that entry is production (dev uses `async`).
- **Channels:** there are no custom channels, only `ApplicationCable`. Every real-time update is a Turbo Stream broadcast, from `Message`, `Chat#add_error`, `GenerateInsightsJob` and the Bayes evaluation progress.
- **Langfuse** is called through a local `LangfuseTracing` class (`lib/`), not a gem.
- **Out of scope, though present:** Stripe (billing), OmniAuth/SAML (SSO), the bank-provider syncers, and `RuleNotificationMailer` (a rule email action, not AI).
- The box counts are grouped. "30/44 tools" and "1 thread" are the documented defaults, not measured runtime values.
