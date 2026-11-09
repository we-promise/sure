# Deprecated: reads the AI ENV and `Setting` fields as an AI configuration, so
# installs configured either way keep working while the router replaces today's lookups.
#
# Each value resolves the way the provider code resolves it. Wherever that code has a resolver
# (Provider::Registry and the providers it builds, Assistant::External.config), this calls it, so
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
  # Each generation feature's prompt folder: OpenAI's detailed prompt on native OpenAI, the
  # simplified one on custom servers, and Anthropic's own.
  PROMPTS = {
    categorize: "categorize_transactions", detect_merchants: "detect_merchants",
    enhance_merchants: "enhance_merchants", bill_setup: "bill_setup"
  }.freeze
  SIMPLE_PROMPTS = %i[categorize detect_merchants enhance_merchants].freeze   # bill setup has one OpenAI prompt
  JSON_MODES = Ai::Config::Endpoint::JSON_MODES.map(&:to_s).freeze
  ANTHROPIC_MAX_TOKENS = 4096
  EMBEDDING_TIMEOUT = 120         # VectorStore::Embeddable's client
  EXTERNAL_ASSISTANT_TIMEOUT = 120 # Assistant::External::Client::TIMEOUT_READ

  # The inputs a snapshot depends on, so Ai::Config rebuilds when one changes.
  ENV_PREFIXES = %w[OPENAI_ ANTHROPIC_ LLM_ JEV_ EMBEDDING_ VECTOR_STORE_ EXTERNAL_ASSISTANT_].freeze
  SETTING_FIELDS = %i[
    openai_access_token openai_uri_base openai_model openai_request_timeout anthropic_access_token anthropic_model
    anthropic_base_url llm_provider jev_api_key jev_endpoint jev_model external_assistant_url external_assistant_token
    external_assistant_model external_assistant_agent_id openai_json_mode llm_context_window llm_max_response_tokens
    llm_max_items_per_call
  ].freeze

  def self.build = new.build

  # The prompt variant the providers send for `feature` to this kind of endpoint: Anthropic's own,
  # the simplified one on a custom OpenAI-compatible server, otherwise OpenAI's detailed one.
  def self.prompt_for(feature, endpoint)
    base = PROMPTS[feature.to_sym]
    return unless base && endpoint.protocol != :jev

    if endpoint.protocol == :anthropic then "#{base}_anthropic"
    elsif endpoint.name == "openai_compatible" && SIMPLE_PROMPTS.include?(feature.to_sym) then "#{base}_simple"
    else base
    end
  end

  # The OpenAI endpoint's JSON mode: LLM_JSON_MODE, then the saved setting, then auto.
  def self.openai_json_mode
    [ ENV["LLM_JSON_MODE"].presence, Setting.openai_json_mode.presence ].find { JSON_MODES.include?(_1) } || "auto"
  end

  def self.fingerprint
    [ ENV.to_h.select { |name, _| name.start_with?(*ENV_PREFIXES) }.sort, SETTING_FIELDS.map { Setting.public_send(_1) } ].hash
  end

  def build
    @unbuildable = []
    backend = vector_store_backend
    llm = { openai: openai(vector_store: backend == :openai), anthropic: anthropic }.compact
    jev_model = jev
    agent_model = external_assistant
    embed_model = embedding_model if %i[pgvector qdrant].include?(backend)
    embed_route_model = embed_route(backend, llm[:openai], embed_model)

    llm_models = reachable_llm_models(llm)
    # Generation routes list only the preferred LLM, as preferred_llm_provider picks one: failover
    # never sends a family's data to a provider the install doesn't use for that feature. Chat
    # keeps both, as it resolves its own provider.
    preferred = llm_models.first(1)
    routes = LLM_FEATURES.index_with { |feature| route_list(feature, preferred) }
    routes[:chat] = route_list(:chat, llm_models + [ agent_model ].compact)
    routes[:categorize] = route_list(:categorize, [ jev_model, *preferred ].compact, conditions: { jev_model => :jev_family })
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
        vector_store:, json_mode: openai_json_mode
      )
      model = provider && llm_model(endpoint, provider, context_window: uri_base ? context_window : explicit_context_window,
                                    max_output_tokens: positive(env("LLM_MAX_RESPONSE_TOKENS"), Setting.llm_max_response_tokens))
      [ endpoint, model ]
    end

    def anthropic
      token = env("ANTHROPIC_ACCESS_TOKEN") || env("ANTHROPIC_API_KEY") || Setting.anthropic_access_token.presence
      return unless token

      base_url = env("ANTHROPIC_BASE_URL") || Setting.anthropic_base_url.presence
      provider = buildable(:anthropic) { Provider::Registry.get_provider(:anthropic) }
      endpoint = Ai::Config::Endpoint.new(
        name: "anthropic", protocol: :anthropic, preset: (:anthropic unless base_url), base_url:, api_key: token,
        location: location_for(base_url), timeout_seconds: ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i
      )
      model = provider && llm_model(endpoint, provider,
                                    context_window: explicit_context_window,
                                    max_output_tokens: positive(env("ANTHROPIC_MAX_TOKENS")) || ANTHROPIC_MAX_TOKENS)
      [ endpoint, model ]
    end

    # What the providers accept: chat's prefix allow-list decides `tools` and `streaming`, and
    # PDF support decides `vision` and `documents`. Every LLM model does structured output.
    def llm_model(endpoint, provider, context_window:, max_output_tokens:)
      name = provider.default_model
      capabilities = %i[structured_output]
      capabilities += %i[tools streaming] if provider.supports_model?(name)
      capabilities += %i[vision documents] if provider.supports_pdf_processing?(model: name)
      Ai::Config::Model.new(endpoint:, name:, capabilities:, context_window:, max_output_tokens:, batch_size:)
    end

    # The deprecated budgets: on a custom server, Assistant::TokenBudget's window (2048 by default,
    # a guard for small local models); the response cap only when someone set one; and
    # LLM_MAX_ITEMS_PER_CALL items per call.
    def context_window = Assistant::TokenBudget.context_window

    # A cloud model's real window is far larger than the 2048 guard, which would split its batches
    # into several calls, so native OpenAI and Anthropic are token-sliced only when one is set.
    def explicit_context_window = positive(env("LLM_CONTEXT_WINDOW"), Setting.llm_context_window)

    def batch_size = positive(env("LLM_MAX_ITEMS_PER_CALL"), Setting.llm_max_items_per_call) || Ai::Config::Model::DEFAULT_BATCH_SIZE

    def openai_json_mode = self.class.openai_json_mode

    def positive(*values) = values.map(&:to_i).find(&:positive?)

    # Jev serves only families that chose it (Ai::Route#serves?), and only when it can be built:
    # its constructor refuses a cleartext endpoint off localhost.
    def jev
      provider = buildable(:jev) { Provider::Registry.get_provider(:jev) }
      return unless provider

      base_url = Provider::Jev.effective_endpoint
      cloud = URI.parse(base_url).scheme == "https"
      endpoint = Ai::Config::Endpoint.new(
        name: "jev", protocol: :jev, preset: cloud ? :jev : :jev_local, base_url:, api_key: Provider::Jev.api_key,
        location: location_for(base_url), timeout_seconds: ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i
      )
      Ai::Config::Model.new(endpoint:, name: provider.default_model,
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
      models.map { |model| Ai::Route.new(feature:, model:, condition: conditions[model], prompt: prompt_for(feature, model)) }
    end

    def prompt_for(feature, model) = self.class.prompt_for(feature, model.endpoint)

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

    # Provider::Registry.preferred_llm_provider walks the same order and raises at a provider
    # that can't be built, so the providers after it are never reached and get no route.
    def reachable_llm_models(llm)
      Provider::Registry.llm_provider_order.each_with_object([]) do |name, models|
        break models if @unbuildable.include?(name)

        models << llm[name].last if llm[name]&.last
      end
    end

    def buildable(name)
      yield
    rescue Provider::Error
      @unbuildable << name
      nil
    end

    def env(name) = ENV[name].presence
end
