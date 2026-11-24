# Helpers for testing AI code: the transport level (endpoints, models, call contexts, captured
# events) and routing (use_ai_routes, use_no_ai).
module AiTestHelper
  LLM_CAPABILITIES = %i[tools vision documents streaming structured_output].freeze

  # One configured setup for every test: a cloud `openai` endpoint, a local `gpu`, an `embed`
  # server, a cloud `jev` and an external assistant (`agent`), with every feature routed.
  def self.test_config
    @test_config ||= begin
      endpoint = ->(name, **attributes) { Ai::Config::Endpoint.new(name:, protocol: :compatible, api_key: "test-key", **attributes) }
      openai = endpoint.(:openai, preset: :openai, responses_api: true)
      gpu = endpoint.(:gpu, base_url: "http://gpu.local:8080/v1", location: :local)
      embed = endpoint.(:embed, base_url: "http://embed.local:8081/v1", location: :local)
      jev = Ai::Config::Endpoint.new(name: :jev, protocol: :jev, preset: :jev, base_url: "https://api.typesafe.ai/v1/systemone", api_key: "test-key")
      agent = endpoint.(:agent, base_url: "https://agent.example.test/v1", agent: true, agent_settings: { allowed_emails: [] })

      models = [
        Ai::Config::Model.new(endpoint: openai, name: "gpt-4.1-mini", capabilities: LLM_CAPABILITIES),
        Ai::Config::Model.new(endpoint: gpu, name: "qwen3-8b", capabilities: LLM_CAPABILITIES - %i[vision documents]),
        Ai::Config::Model.new(endpoint: embed, name: "nomic-embed-text", capabilities: %i[embedding], embedding_dimensions: 768),
        Ai::Config::Model.new(endpoint: jev, name: "jev-latest", capabilities: %i[judge calibrated_confidence]),
        Ai::Config::Model.new(endpoint: agent, name: "openclaw/main")
      ]
      routes = {
        chat: %w[openai/gpt-4.1-mini agent/openclaw/main], bill_setup: %w[openai/gpt-4.1-mini],
        extract_pdf: %w[openai/gpt-4.1-mini], embed: %w[embed/nomic-embed-text], categorize: %w[openai/gpt-4.1-mini],
        shadow_categorize: %w[jev/jev-latest], detect_merchants: %w[openai/gpt-4.1-mini],
        enhance_merchants: %w[openai/gpt-4.1-mini]
      }
      build_ai_config(models, routes, vector_store_backend: :pgvector)
    end
  end

  # routes: feature => ["endpoint/model", ...], resolved against `models`.
  def self.build_ai_config(models, routes, vector_store_backend: nil)
    lookup = models.index_by { "#{_1.endpoint.name}/#{_1.name}" }
    built = routes.to_h do |feature, names|
      [ feature, names.map { |name| Ai::Route.new(feature:, model: lookup.fetch(name)) } ]
    end
    Ai::Config.new(endpoints: models.map(&:endpoint).uniq, models:, routes: built, vector_store_backend:)
  end

  def self.included(base)
    base.teardown { Ai::Config.override = nil } if base.respond_to?(:teardown)
  end

  # Routes AI through the test setup for the rest of the test, with the named features' routes
  # replaced; the teardown restores the built config.
  #   use_ai_routes
  #   use_ai_routes(categorize: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
  #   use_ai_routes(chat: [])   # chat :not_configured, everything else routed
  def use_ai_routes(vector_store_backend: :pgvector, **routes)
    base = AiTestHelper.test_config
    names = base.routes.transform_values { |list| list.map { "#{_1.endpoint.name}/#{_1.model.name}" } }
    Ai::Config.override = AiTestHelper.build_ai_config(base.models, names.merge(routes), vector_store_backend:)
  end

  # No AI configured for the rest of the test: every feature is :not_configured.
  def use_no_ai = Ai::Config.override = Ai::Config.new

  def ai_endpoint(name: "test", protocol: :compatible, base_url: "https://llm.example.test/v1", api_key: "test-key", **attributes)
    Ai::Config::Endpoint.new(name:, protocol:, base_url:, api_key:, **attributes)
  end

  def ai_model(name: "test-model", endpoint: ai_endpoint, **attributes)
    Ai::Config::Model.new(endpoint:, name:, **attributes)
  end

  # Runs the block inside a call context, as a transport would.
  def with_ai_call_context(feature: :test, model: ai_model, family: nil, budget: nil, &block)
    Ai::CallContext.call(feature:, model:, family:, budget:, &block)
  end

  # The `.ai` events the block emits (or any other pattern's events).
  def capture_ai_events(pattern = /\.ai\z/)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(pattern) { |event| events << event }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
