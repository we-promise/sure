# End-to-end AI tests (test/e2e/ai/): the app configured the way a self-hoster configures it
# (the AI ENV that Ai::LegacyEnvConfig reads), against free live models, through the real entry
# points. Run with AI_E2E=1; `ai-e2e.yml` runs them on every v* tag. Without it they skip, so
# `bin/rails test` stays offline.
#
# Assertions check shape (records changed, usage written, no error logged), never accuracy:
# that's the evals' job.
module AiE2eHelper
  KILO_URL = "https://api.kilo.ai/api/gateway".freeze
  KILO_MODEL = "kilo-auto/free".freeze
  # OpenCode Zen's free Jev, at a TypeSafe-style path, with its anonymous key.
  JEV_URL = "https://opencode.ai/zen/v1/systemone".freeze
  JEV_MODEL = "jev-1.13-free".freeze
  # Ai::LegacyEnvConfig's 2,048-token guard for custom servers is for small local models; a
  # self-hoster on a gateway sets a real window, and chat's tool list doesn't fit the guard.
  CONTEXT_WINDOW = "32000".freeze
  # A free reasoning model reading a whole statement takes longer than the 60-second default.
  REQUEST_TIMEOUT = "300".freeze
  # Cohere's OpenAI-compatible embeddings, on a free trial key: the one leg that needs a key.
  COHERE_KEY = "COHERE_LIVE_API_KEY".freeze
  COHERE_EMBEDDING_URL = "https://api.cohere.ai/compatibility/v1".freeze
  COHERE_EMBEDDING_MODEL = "embed-v5.0-fast".freeze
  COHERE_EMBEDDING_DIMENSIONS = "2048".freeze

  def self.included(base)
    base.setup do
      skip "set AI_E2E=1 to run against live models" unless ENV["AI_E2E"] == "1"

      Ai::Config.override = nil
      Ai::LegacyEnvConfig.unreachably_warned = nil
    end
  end

  # Kilo's gateway as the OpenAI-compatible LLM; `jev: true` makes Jev categorize, with Kilo as its
  # shadow. Kilo's free model answers anonymously; KILO_API_KEY and KILO_ORG_ID, when set, raise
  # its rate limits.
  def with_live_ai(jev: false, **extra, &block)
    with_env_overrides(kilo_env.merge(jev ? jev_env : {}).merge(extra)) { with_ai_live(&block) }
  end

  # Documents on pgvector, embedded by Cohere: what a self-hoster sets for a hosted embedding
  # model. Skips, naming the variable, without a key.
  def cohere_embeddings
    skip "set #{COHERE_KEY} to run the embeddings leg" if ENV[COHERE_KEY].blank?

    { VECTOR_STORE_PROVIDER: "pgvector", EMBEDDING_URI_BASE: COHERE_EMBEDDING_URL, EMBEDDING_MODEL: COHERE_EMBEDDING_MODEL,
      EMBEDDING_DIMENSIONS: COHERE_EMBEDDING_DIMENSIONS, EMBEDDING_ACCESS_TOKEN: ENV[COHERE_KEY] }
  end

  def assert_ai_usage(family, feature)
    rows = family.llm_usages.where(operation: feature.to_s)
    assert rows.exists?, "no llm_usages row for #{feature}"
    assert_equal [ "succeeded" ], rows.distinct.pluck(:status), "a #{feature} call failed: #{rows.where.not(status: "succeeded").pluck(:metadata)}"
  end

  def assert_no_ai_errors
    errors = DebugLogEntry.where(level: "error").pluck(:source, :message, :metadata)
    assert_empty errors, "errors logged during the run"
  end

  private
    def kilo_env
      {
        OPENAI_ACCESS_TOKEN: ENV["KILO_API_KEY"].presence || "anonymous",
        OPENAI_URI_BASE: KILO_URL,
        OPENAI_MODEL: KILO_MODEL,
        OPENAI_EXTRA_HEADERS: ({ "X-KiloCode-OrganizationId" => ENV["KILO_ORG_ID"] }.to_json if ENV["KILO_ORG_ID"].present?),
        LLM_CONTEXT_WINDOW: CONTEXT_WINDOW,
        OPENAI_REQUEST_TIMEOUT: REQUEST_TIMEOUT,
        LLM_PROVIDER: "openai",
        ANTHROPIC_API_KEY: nil, ANTHROPIC_ACCESS_TOKEN: nil, VECTOR_STORE_PROVIDER: nil,
        CATEGORIZATION_PROVIDER: "llm", JEV_API_KEY: nil
      }
    end

    def jev_env
      {
        CATEGORIZATION_PROVIDER: "jev",
        JEV_API_KEY: ENV["JEV_LIVE_API_KEY"].presence || "public",
        JEV_ENDPOINT: JEV_URL,
        JEV_MODEL: JEV_MODEL
      }
    end
end
