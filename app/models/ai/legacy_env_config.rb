# Deprecated: reads the AI ENV and `Setting` fields as an AI configuration, so
# installs configured either way keep working while the router replaces today's lookups.
#
# Each value resolves the way today's code resolves it. Wherever today's code has a resolver
# (Provider::Registry, Provider::*.effective_*, Assistant::External.config, Ai::LegacyEnvConfig::Jev), this calls it, so
# the router and the calls not yet on the router can't disagree. test/architecture/ai_config_test
# checks that over every documented setup. The one deliberate difference is drift bug 5:
# embeddings fall back to the OpenAI values saved in Settings, as every other AI setting does.
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
  JSON_MODES = %w[strict json_object none auto].freeze   # LLM_JSON_MODE values today
  ANTHROPIC_MAX_TOKENS = 4096
  EMBEDDING_TIMEOUT = 120         # VectorStore::Embeddable's client
  EXTERNAL_ASSISTANT_TIMEOUT = 120 # Assistant::External::Client::TIMEOUT_READ
  JEV_RETRIES = 3                  # what the hand-written Jev client retried
  JEV_UNSUPPORTED = {
    openrouter: "OpenRouter's Jev needs RubyLLM 2.2 (PR 5)",
    path: "only TypeSafe-style …/v1/systemone endpoints are supported"
  }.freeze

  # The inputs a snapshot depends on, so Ai::Config rebuilds when one changes.
  ENV_PREFIXES = %w[OPENAI_ ANTHROPIC_ LLM_ JEV_ EMBEDDING_ VECTOR_STORE_ EXTERNAL_ASSISTANT_ CATEGORIZATION_PROVIDER].freeze
  SETTING_FIELDS = %i[
    openai_access_token openai_uri_base openai_model openai_request_timeout anthropic_access_token anthropic_model
    anthropic_base_url llm_provider jev_api_key jev_endpoint jev_model external_assistant_url external_assistant_token
    external_assistant_model external_assistant_agent_id openai_json_mode llm_context_window llm_max_response_tokens
    llm_max_items_per_call categorization_provider
  ].freeze
  CATEGORIZATION_PROVIDERS = %w[llm jev].freeze

  def self.build = new.build

  # Which model categorizes every family's transactions: CATEGORIZATION_PROVIDER, then the
  # instance's setting, else the LLM. Until 2d this was a family column; with one family its
  # choice was copied to the setting (2d plan, decision 2).
  def self.categorization_provider
    [ ENV["CATEGORIZATION_PROVIDER"].presence, Setting.categorization_provider.presence ]
      .find { CATEGORIZATION_PROVIDERS.include?(_1) } || "llm"
  end

  # The prompt variant today's code sends for `feature` to this kind of endpoint: Anthropic's own,
  # the simplified one on a custom OpenAI-compatible server, otherwise OpenAI's detailed one.
  def self.prompt_for(feature, endpoint)
    base = PROMPTS[Ai::Routes.source_of(feature)]
    return unless base && endpoint.protocol != :jev

    if endpoint.protocol == :anthropic then "#{base}_anthropic"
    elsif endpoint.name == "openai_compatible" && SIMPLE_PROMPTS.include?(feature.to_sym) then "#{base}_simple"
    else base
    end
  end

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
    # Generation routes list only the preferred LLM: failover never sends a family's data to a
    # provider the install doesn't use for that feature. Chat keeps both, as it resolves its own
    # provider.
    preferred = llm_models.first(1)
    routes = LLM_FEATURES.index_with { |feature| route_list(feature, preferred) }
    # Today's rule for PDF import: only a provider whose PDF support is on (supports_pdf_processing?,
    # which `vision` carries), so OPENAI_SUPPORTS_PDF_PROCESSING=false keeps it off (2e plan;
    # editable per model from PR 7).
    routes[:extract_pdf] = route_list(:extract_pdf, preferred.select { _1.capable?(:vision) }.map { pdf_model(_1) })
    routes[:chat] = route_list(:chat, llm_models + [ agent_model ].compact)
    # Jev or the LLM, never both, so a Jev outage doesn't send a batch to the LLM (2d plan,
    # decision 3); the shadow route runs the other one, as the family's shadow provider did.
    jev_first = jev_model && self.class.categorization_provider == "jev"
    routes[:categorize] = route_list(:categorize, jev_first ? [ jev_model ] : preferred)
    routes[:shadow_categorize] = route_list(:shadow_categorize, jev_first ? preferred : [ jev_model ].compact)
    routes[:embed] = route_list(:embed, [ embed_route_model ].compact)

    endpoints = (llm.values.map(&:first) + [ jev_model, agent_model, embed_model ].compact.map(&:endpoint)).uniq
    models = (llm_models + [ jev_model, agent_model, embed_model, embed_route_model ]).compact.uniq

    Ai::Config.new(endpoints:, models:, routes: routes.reject { |_, list| list.empty? }, vector_store_backend: backend)
  end

  private
    # [endpoint, model or nil]. A custom URL without a model gets an endpoint and no model, as
    # today's registry builds no client for it (Setting.validate_openai_config!, #4408).
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
      name = Provider::Openai.effective_model
      flag = env("OPENAI_SUPPORTS_PDF_PROCESSING")
      vision = (flag.nil? || flag.downcase.in?(%w[true 1 yes])) &&
               (uri_base.present? || Provider::Openai::VISION_CAPABLE_MODEL_PREFIXES.any? { name.start_with?(_1) })
      model = provider && llm_model(endpoint, provider, name, context_window: context_window,
                                    max_output_tokens: positive(env("LLM_MAX_RESPONSE_TOKENS"), Setting.llm_max_response_tokens),
                                    vision:, documents: vision && uri_base.nil?)
      [ endpoint, model ]
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
      # Today's Anthropic batches aren't token-sliced, so its window is known only when set.
      name = Provider::Anthropic.effective_model
      vision = base_url.present? || Provider::Anthropic::VISION_CAPABLE_MODEL_PREFIXES.any? { name.to_s.start_with?(_1) }
      model = provider && llm_model(endpoint, provider, name,
                                    context_window: positive(env("LLM_CONTEXT_WINDOW"), Setting.llm_context_window),
                                    max_output_tokens: positive(env("ANTHROPIC_MAX_TOKENS")) || ANTHROPIC_MAX_TOKENS,
                                    vision:, documents: vision)
      [ endpoint, model ]
    end

    # What today's providers accept: chat's prefix allow-list decides `tools` and `streaming`, and
    # today's PDF support decides `vision` (a custom server is trusted with images, as today, unless
    # OPENAI_SUPPORTS_PDF_PROCESSING is off, which also keeps it out of PDF import). `documents`, a PDF sent as a file, only where the
    # provider reads one natively: Anthropic and OpenAI's own API. llama.cpp and Gemini's
    # compatible API refuse RubyLLM's file part, and OpenRouter bills parsing it (2e plan).
    # Every LLM model does structured output.
    def llm_model(endpoint, provider, name, context_window:, max_output_tokens:, vision:, documents:)
      capabilities = %i[structured_output]
      capabilities += %i[tools streaming] if provider.supports_model?(name)
      capabilities << :vision if vision
      capabilities << :documents if documents
      Ai::Config::Model.new(endpoint:, name:, capabilities:, context_window:, max_output_tokens:, batch_size:)
    end

    # Today's budgets: Assistant::TokenBudget's window (2048 by default), the response cap only
    # when someone set one, and LLM_MAX_ITEMS_PER_CALL items per call.
    def context_window = Assistant::TokenBudget.context_window

    # Today's PDF import ignores the 2,048-token baseline chat and categorization assume: it sends
    # the pages in one request and the text in 3,000-character chunks. So unless the operator set
    # LLM_CONTEXT_WINDOW, extract_pdf's model has no window, which Ai::PdfReading reads the same
    # way, splitting a batch only when the server says it's too long.
    def pdf_model(model)
      positive(env("LLM_CONTEXT_WINDOW"), Setting.llm_context_window) ? model : model.with(context_window: nil)
    end

    def batch_size = positive(env("LLM_MAX_ITEMS_PER_CALL"), Setting.llm_max_items_per_call) || Ai::Config::Model::DEFAULT_BATCH_SIZE

    def openai_json_mode
      [ env("LLM_JSON_MODE"), Setting.openai_json_mode.presence ].find { JSON_MODES.include?(_1) } || "auto"
    end

    def positive(*values) = values.map(&:to_i).find(&:positive?)

    # Jev, when RubyLLM can reach it: a TypeSafe-style `…/v1/systemone` URL, http only for a server on a private network
    # (section 7). An endpoint it can't reach is left out with a warning, so `categorize` uses
    # the LLM, as today when Jev can't be built.
    def jev
      return unless Jev.configured?

      url = Jev.effective_endpoint
      reason = Jev.unreachable_reason(url)
      if reason
        Rails.logger.warn("[Ai::LegacyEnvConfig] Jev left out: #{Jev.redacted_endpoint(url)}: #{JEV_UNSUPPORTED.fetch(reason)}")
        return
      end

      base_url = Jev.base_url(url)
      location = location_for(base_url)
      endpoint = Ai::Config::Endpoint.new(
        name: "jev", protocol: :jev, preset: location == :cloud ? :jev : :jev_local, base_url:, api_key: Jev.api_key,
        location:, timeout_seconds: ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i, max_retries: JEV_RETRIES,
        parallel_requests: positive(env("JEV_CONCURRENCY"))
      )
      Ai::Config::Model.new(endpoint:, name: Jev.effective_model,
                            capabilities: location == :cloud ? %i[judge calibrated_confidence] : %i[judge])
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

    # Today's VectorStore::Registry.adapter_name: VECTOR_STORE_PROVIDER, else pgvector on
    # Anthropic installs, else OpenAI's store when there's an OpenAI key.
    def vector_store_backend
      explicit = env("VECTOR_STORE_PROVIDER")&.to_sym
      return explicit if explicit && VectorStore::Registry::ADAPTERS.key?(explicit)
      return :pgvector if Setting.llm_provider == "anthropic"

      :openai if env("OPENAI_ACCESS_TOKEN") || Setting.openai_access_token.present?
    end

    # The `embed` route's model, present exactly when today's registry would build an adapter.
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

    # Drift bug 5: the URL and key fall back to the OpenAI values saved in Settings too.
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

    def route_list(feature, models)
      models.each_with_index.map do |model, position|
        Ai::Route.new(feature:, position:, model:, prompt: prompt_for(feature, model))
      end
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

    def buildable
      yield
    rescue Provider::Error
      nil
    end

    def env(name) = ENV[name].presence
end
