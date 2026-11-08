# Deprecated: reads the AI ENV and `Setting` fields as an AI configuration, so
# installs configured either way keep working while the router replaces today's lookups.
#
# Each value resolves the way the provider code resolves it. Wherever that code has a resolver
# (Provider::Registry, Provider::*.effective_*, Assistant::External.config), this calls it, so
# the router and the calls not yet on the router can't disagree. test/architecture/ai_config_test
# checks that over every documented setup. The one deliberate difference: embeddings fall back
# to the OpenAI values saved in Settings, as every other AI setting does.
#
# It's built in every process. The release that stops reading the old variables deletes this file.
class Ai::LegacyEnvConfig
  # OpenAI's vector store embeds files on its own side, so the `embed` route names this stand-in
  # model on the OpenAI endpoint.
  VECTOR_STORE_MODEL = "vector_store".freeze
  LLM_FEATURES = %i[bill_setup extract_pdf detect_merchants enhance_merchants].freeze
  EMBEDDING_TIMEOUT = 120         # VectorStore::Embeddable's client
  EXTERNAL_ASSISTANT_TIMEOUT = 120 # Assistant::External::Client::TIMEOUT_READ

  # The inputs a snapshot depends on, so Ai::Config rebuilds when one changes.
  ENV_PREFIXES = %w[OPENAI_ ANTHROPIC_ LLM_ JEV_ EMBEDDING_ VECTOR_STORE_ EXTERNAL_ASSISTANT_].freeze
  SETTING_FIELDS = %i[
    openai_access_token openai_uri_base openai_model openai_request_timeout anthropic_access_token anthropic_model
    anthropic_base_url llm_provider jev_api_key jev_endpoint jev_model external_assistant_url external_assistant_token
    external_assistant_model external_assistant_agent_id
  ].freeze

  def self.build = new.build

  def self.fingerprint
    [ ENV.to_h.select { |name, _| name.start_with?(*ENV_PREFIXES) }.sort, SETTING_FIELDS.map { Setting.public_send(_1) } ].hash
  end

  def build
    backend = vector_store_backend
    llm = { openai: openai(vector_store: backend == :openai), anthropic: anthropic }.compact
    jev_model = jev
    agent_model = external_assistant
    embed_model = embedding_model if %i[pgvector qdrant].include?(backend)
    embed_route_model = embed_route(backend, llm[:openai], embed_model)

    llm_models = Provider::Registry.llm_provider_order.filter_map { |name| llm[name]&.last }
    routes = LLM_FEATURES.index_with { |feature| route_list(feature, llm_models) }
    routes[:chat] = route_list(:chat, llm_models + [ agent_model ].compact)
    routes[:categorize] = route_list(:categorize, [ jev_model, *llm_models ].compact, conditions: { jev_model => :jev_family })
    routes[:embed] = route_list(:embed, [ embed_route_model ].compact)

    endpoints = (llm.values.map(&:first) + [ jev_model, agent_model, embed_model ].compact.map(&:endpoint)).uniq
    models = (llm_models + [ jev_model, agent_model, embed_model, embed_route_model ]).compact.uniq

    Ai::Config.new(endpoints:, models:, routes: routes.reject { |_, list| list.empty? }, vector_store_backend: backend)
  end

  private
    # [endpoint, model or nil]. A custom URL without a model gets an endpoint and no model, as
    # Provider::Registry builds no client for it (Setting.validate_openai_config!, #4408).
    def openai(vector_store:)
      token = env("OPENAI_ACCESS_TOKEN") || Setting.openai_access_token.presence
      return unless token

      uri_base = openai_uri_base
      provider = Provider::Registry.get_provider(:openai)
      endpoint = Ai::Config::Endpoint.new(
        name: uri_base ? "openai_compatible" : "openai", protocol: :compatible, preset: (:openai unless uri_base),
        base_url: uri_base, api_key: token, extra_headers: static_openai_headers, location: location_for(uri_base),
        timeout_seconds: Provider::Openai.request_timeout, responses_api: provider&.supports_responses_endpoint? || false,
        vector_store:
      )
      [ endpoint, provider && llm_model(endpoint, provider, Provider::Openai.effective_model) ]
    end

    def anthropic
      token = env("ANTHROPIC_ACCESS_TOKEN") || env("ANTHROPIC_API_KEY") || Setting.anthropic_access_token.presence
      return unless token

      base_url = env("ANTHROPIC_BASE_URL") || Setting.anthropic_base_url.presence
      provider = buildable { Provider::Registry.get_provider(:anthropic) }
      endpoint = Ai::Config::Endpoint.new(
        name: "anthropic", protocol: :anthropic, preset: (:anthropic unless base_url), base_url:, api_key: token,
        location: location_for(base_url), timeout_seconds: ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i
      )
      [ endpoint, provider && llm_model(endpoint, provider, Provider::Anthropic.effective_model) ]
    end

    # What the providers accept: chat's prefix allow-list decides `tools` and `streaming`, and
    # PDF support decides `vision` and `documents`. Every LLM model does structured output.
    def llm_model(endpoint, provider, name)
      capabilities = %i[structured_output]
      capabilities += %i[tools streaming] if provider.supports_model?(name)
      capabilities += %i[vision documents] if provider.supports_pdf_processing?(model: name)
      Ai::Config::Model.new(endpoint:, name:, capabilities:)
    end

    # Jev serves only families that chose it (Ai::Route#serves?), and only when it can be built:
    # its constructor refuses a cleartext endpoint off localhost.
    def jev
      return unless buildable { Provider::Registry.get_provider(:jev) }

      base_url = Provider::Jev.effective_endpoint
      cloud = URI.parse(base_url).scheme == "https"
      endpoint = Ai::Config::Endpoint.new(
        name: "jev", protocol: :jev, preset: cloud ? :jev : :jev_local, base_url:, api_key: Provider::Jev.api_key,
        location: location_for(base_url), timeout_seconds: ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i
      )
      Ai::Config::Model.new(endpoint:, name: Provider::Jev.effective_model,
                            capabilities: cloud ? %i[judge calibrated_confidence] : %i[judge])
    end

    def external_assistant
      return unless Assistant::External.configured?

      config = Assistant::External.config
      allowed = env("EXTERNAL_ASSISTANT_ALLOWED_EMAILS").to_s.split(",").map { _1.strip.downcase }.compact_blank
      endpoint = Ai::Config::Endpoint.new(
        name: "external_assistant", protocol: :compatible, base_url: config.url, api_key: config.token,
        location: location_for(config.url), timeout_seconds: EXTERNAL_ASSISTANT_TIMEOUT, agent: true,
        agent_settings: { allowed_emails: allowed, agent_id: config.agent_id, session_key: config.session_key }
      )
      Ai::Config::Model.new(endpoint:, name: config.model)
    end

    # The vector store rule VectorStore::Registry used: VECTOR_STORE_PROVIDER, else pgvector on
    # Anthropic installs, else OpenAI's store when there's an OpenAI key.
    def vector_store_backend
      explicit = env("VECTOR_STORE_PROVIDER")&.to_sym
      return explicit if explicit && VectorStore::Registry::ADAPTERS.key?(explicit)
      return :pgvector if Setting.llm_provider == "anthropic"

      :openai if env("OPENAI_ACCESS_TOKEN") || Setting.openai_access_token.present?
    end

    # The `embed` route's model, present exactly when VectorStore::Registry can build an adapter.
    # pgvector without the extension keeps its embedding model in the config, for the health page.
    def embed_route(backend, openai, embed_model)
      case backend
      when :openai
        Ai::Config::Model.new(endpoint: openai.first, name: VECTOR_STORE_MODEL, capabilities: %i[embedding]) if openai
      when :pgvector
        embed_model if VectorStore::Pgvector.available?
      when :qdrant
        embed_model
      end
    end

    # The URL and key fall back to the OpenAI values saved in Settings too.
    def embedding_model
      base_url = env("EMBEDDING_URI_BASE") || openai_uri_base || VectorStore::DEFAULT_EMBEDDING_URI_BASE
      api_key = env("EMBEDDING_ACCESS_TOKEN") || env("OPENAI_ACCESS_TOKEN") || Setting.openai_access_token.presence
      endpoint = Ai::Config::Endpoint.new(
        name: "embed", protocol: :compatible, base_url:, api_key:, location: location_for(base_url),
        timeout_seconds: EMBEDDING_TIMEOUT
      )
      Ai::Config::Model.new(
        endpoint:, name: ENV.fetch("EMBEDDING_MODEL", VectorStore::DEFAULT_EMBEDDING_MODEL), capabilities: %i[embedding],
        embedding_dimensions: ENV.fetch("EMBEDDING_DIMENSIONS", VectorStore::DEFAULT_EMBEDDING_DIMENSIONS).to_i
      )
    end

    def route_list(feature, models, conditions: {})
      models.each_with_index.map do |model, position|
        Ai::Route.new(feature:, position:, model:, condition: conditions[model])
      end
    end

    def openai_uri_base = env("OPENAI_URI_BASE") || Setting.openai_uri_base.presence

    # Session-valued headers ({session_id}) are filled per chat request, so only chat sends them.
    def static_openai_headers
      Provider::Openai.extra_headers.reject { |_, value| value.include?("{session_id}") }
    end

    # http is a server on a private network; https, or no URL (the provider's own), is cloud.
    def location_for(url)
      url.present? && URI.parse(url).scheme == "http" ? :local : :cloud
    rescue URI::InvalidURIError
      :cloud
    end

    def buildable
      yield
    rescue Provider::Error
      nil
    end

    def env(name) = ENV[name].presence
end
