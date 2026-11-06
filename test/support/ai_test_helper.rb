# Helpers for testing AI code (ai-plumbing-redesign.md, section 17). 2a brings the transport
# level, 2b the routing (with_ai_routes, without_ai); 2c adds stub_ai, PR 3 with_ai_capsule.
module AiTestHelper
  LLM_CAPABILITIES = %i[tools vision documents streaming structured_output].freeze

  # One configured setup for every test (section 17): a cloud `openai` endpoint, a local `gpu`, an
  # `embed` server, a cloud `jev` and an external assistant (`agent`), with every feature routed.
  # PR 7 replaces it with table fixtures.
  def self.test_config
    @test_config ||= begin
      endpoint = ->(name, **attributes) { Ai::Config::Endpoint.new(name:, protocol: :compatible, api_key: "test-key", **attributes) }
      openai = endpoint.(:openai, preset: :openai, responses_api: true)
      gpu = endpoint.(:gpu, base_url: "http://gpu.local:8080/v1", location: :local)
      embed = endpoint.(:embed, base_url: "http://embed.local:8081/v1", location: :local)
      jev = Ai::Config::Endpoint.new(name: :jev, protocol: :jev, preset: :jev, base_url: "https://api.typesafe.ai", api_key: "test-key")
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
      [ feature, names.each_with_index.map { |name, position| Ai::Route.new(feature:, position:, model: lookup.fetch(name)) } ]
    end
    Ai::Config.new(endpoints: models.map(&:endpoint).uniq, models:, routes: built, vector_store_backend:)
  end

  def self.included(base)
    return unless base.respond_to?(:teardown)

    base.teardown do
      Ai::Config.override = nil
      AiTestHelper.transport_stub = nil
    end
  end

  class << self
    # Set by stub_ai: builds the transport for an endpoint instead of Ai::Transport.for.
    attr_accessor :transport_stub
  end

  # Ai::Transport.for asks the stub first, so stub_ai covers every route, whatever its endpoint.
  module TransportStub
    def for(endpoint) = AiTestHelper.transport_stub ? AiTestHelper.transport_stub.call(endpoint) : super
  end
  Ai::Transport.singleton_class.prepend(TransportStub)

  # A transport that answers `generate` and `judge` from the test, through Ai::Transport::Base,
  # so the call context and the `.ai` events are the real ones.
  class FakeTransport < Ai::Transport::Base
    def initialize(endpoint, responder)
      super(endpoint)
      @responder = responder
    end

    private
      def run_generate(request)
        answer = @responder.call(request)
        Response.new(json: JSON.parse(answer.to_json), usage: Ai::Tokens.new(input_tokens: 10, output_tokens: 5),
                     raw_id: "stub", finish_reason: :stop, json_mode: request.json_mode)
      end

      # The test answers { item id => { question => answer } }; an answer is a RubyLLM answer, a
      # category name, or [name, confidence]. A missing id is a malformed answer.
      def run_judge(request)
        given = @responder.call(request).to_h.transform_keys(&:to_s)
        answers = request.states.keys.to_h do |id|
          [ id, given[id]&.to_h { |name, answer| [ name.to_sym, AiTestHelper.judge_answer(answer) ] } ]
        end
        JudgeResponse.new(answers:, usage: Ai::Tokens.new(input_tokens: 10 * answers.size, output_tokens: 0))
      end
  end

  def self.judge_answer(answer)
    return answer unless answer.is_a?(String) || answer.is_a?(Array)

    choice, confidence = Array(answer)
    confidence ||= 0.9
    RubyLLM::Choice.new(choice:, probabilities: { choice => confidence }, confidence:)
  end

  # Makes `feature`'s generations answer `returns` (a value, or a proc taking the request), or
  # raise `raises`, with no HTTP. Coercion, failover, instrumentation and the requester still
  # run. Returns the requests sent, in order. A request for another feature fails the test.
  # On a `judge` route the request is a JudgeRequest, answered by item id (FakeTransport#run_judge):
  #   stub_ai(:categorize) { |request| request.states.keys.index_with { { category: "Groceries" } } }
  #   requests = stub_ai(:categorize, returns: { categorizations: [ ... ] })
  #   stub_ai(:bill_setup, raises: Ai::Error::Timeout)
  #   stub_ai { |request| request.model.endpoint.name == "gpu" ? raise(Ai::Error::InvalidOutput) : { ... } }
  def stub_ai(feature = nil, returns: nil, raises: nil, &block)
    requests = []
    responder = lambda do |request|
      raise ArgumentError, "stub_ai(#{feature.inspect}) got a #{request.feature} request" if feature && request.feature != feature.to_sym

      requests << request
      raise raises if raises
      next block.call(request) if block

      returns.respond_to?(:call) ? returns.call(request) : returns
    end
    AiTestHelper.transport_stub = ->(endpoint) { FakeTransport.new(endpoint, responder) }
    requests
  end

  # The block forms below, for a whole test (integration tests, setup blocks):
  #   use_ai_routes(bill_setup: %w[gpu/qwen3-8b])
  #   use_no_ai
  def use_ai_routes(**routes) = Ai::Config.override = ai_routes_config(**routes)

  def use_no_ai = Ai::Config.override = Ai::Config.new

  # Runs the block with the test setup, its named features' routes replaced:
  #   with_ai_routes(categorize: ["gpu/qwen3-8b", "openai/gpt-4.1-mini"]) { ... }
  #   with_ai_routes(chat: []) { ... }   # chat :not_configured, everything else routed
  def with_ai_routes(**routes, &block)
    Ai::Config.with(ai_routes_config(**routes), &block)
  end

  def ai_routes_config(vector_store_backend: :pgvector, **routes)
    base = AiTestHelper.test_config
    names = base.routes.transform_values { |list| list.map { "#{_1.endpoint.name}/#{_1.model.name}" } }
    AiTestHelper.build_ai_config(base.models, names.merge(routes.transform_keys(&:to_sym)), vector_store_backend:)
  end

  # Runs the block with the test setup's openai/gpt-4.1-mini changed, for budgets and the like:
  #   with_ai_model_settings(batch_size: 2) { ... }
  def with_ai_model_settings(**attributes, &block)
    base = AiTestHelper.test_config
    models = base.models.map { _1.endpoint.name == "openai" ? _1.with(**attributes) : _1 }
    names = base.routes.transform_values { |list| list.map { "#{_1.endpoint.name}/#{_1.model.name}" } }
    Ai::Config.with(AiTestHelper.build_ai_config(models, names, vector_store_backend: base.vector_store_backend), &block)
  end

  # Runs the block with no AI configured: every feature is :not_configured.
  def without_ai(&block)
    Ai::Config.with(Ai::Config.new, &block)
  end
  AI_CASSETTE_KEYS = %w[OPENAI_ACCESS_TOKEN ANTHROPIC_API_KEY OPENROUTER_API_KEY LLAMA_CPP_API_KEY LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY].freeze

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

  # Makes every transport for `protocol` answer `probe` with `returns` (or raise `raises`),
  # without HTTP. Returns the recorded [model, check] pairs.
  def stub_ai_transport(protocol = :compatible, returns: nil, raises: nil)
    calls = []
    klass = protocol == :anthropic ? Ai::Transport::Anthropic : Ai::Transport::Compatible
    expectation = klass.any_instance.stubs(:run_probe).with { |model, check, **| calls << [ model, check ] }
    raises ? expectation.raises(raises) : expectation.returns(returns)
    calls
  end

  # Replays (or, with RECORD_CASSETTES=1 and the keys in ENV, records) a cassette under
  # test/vcr_cassettes/ai/<preset>/. Local servers listen on localhost, which Sure's VCR setup
  # ignores, so localhost is recorded inside the block only. Keys are filtered.
  #
  # With AI_LIVE=1 (the `ai-live` label's workflow) the block runs against the real provider
  # instead, with VCR off.
  def with_ai_cassette(preset, name, match: %i[method uri], &block)
    return with_ai_live(&block) if ENV["AI_LIVE"] == "1"

    recording = ENV["RECORD_CASSETTES"] == "1"
    path = "ai/#{preset}/#{name}"
    FileUtils.rm_f(Rails.root.join("test/vcr_cassettes/#{path}.yml")) if recording
    VCR.configuration.ignore_localhost = false
    VCR.use_cassette(path, record: recording ? :all : :none, match_requests_on: match, &block)
  ensure
    VCR.configuration.ignore_localhost = true
  end

  # True when a live test can run: it's recording or live with its key, or replaying a cassette.
  def ai_cassette_available?(preset, name, key:)
    return ENV[key].present? if ENV["AI_LIVE"] == "1" || ENV["RECORD_CASSETTES"] == "1"

    Rails.root.join("test/vcr_cassettes/ai/#{preset}/#{name}.yml").exist?
  end

  def with_ai_live
    config = WebMock::Config.instance
    previous = [ config.allow_net_connect, config.allow_localhost, config.allow ]
    WebMock.allow_net_connect!
    VCR.turned_off(ignore_cassettes: true) { yield }
  ensure
    config.allow_net_connect, config.allow_localhost, config.allow = previous if previous
  end
end

VCR.configure do |config|
  AiTestHelper::AI_CASSETTE_KEYS.each do |key|
    config.filter_sensitive_data("<#{key}>") { ENV[key].presence }
  end
end
