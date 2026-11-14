# Helpers for testing AI code: the transport level (endpoints, models, call contexts, captured
# events, cassettes) and routing (use_ai_routes, use_no_ai).
module AiTestHelper
  # The llama.cpp servers the live tests record against: chat and OCR (LLAMA_CPP_URL) and
  # embeddings (EMBED_LIVE_BASE_URL). Live and recording runs need the variable set; on replay the
  # placeholder host stands in, and cassettes store each URL as a placeholder.
  LIVE_URLS = { "LLAMA_CPP_URL" => "http://llama-cpp.test:8180/v1", "EMBED_LIVE_BASE_URL" => "http://llama-cpp.test:8181/v1" }.freeze

  def self.live_or_recording? = ENV["AI_LIVE"] == "1" || ENV["RECORD_CASSETTES"] == "1"

  # Every {"type": "base64", "data": …} in a JSON body, its data replaced by <FILE>.
  def self.redact_base64_sources(body)
    redact = ->(node) do
      case node
      when Hash then node["type"] == "base64" && node["data"].is_a?(String) ? node.merge("data" => "<FILE>") : node.transform_values(&redact)
      when Array then node.map(&redact)
      else node
      end
    end
    redact.(JSON.parse(body)).to_json
  rescue JSON::ParserError
    body
  end

  def self.live_url(name) = (live_or_recording? && ENV[name].presence) || LIVE_URLS.fetch(name)

  LLAMA_CPP_URL = live_url("LLAMA_CPP_URL").freeze
  EMBED_URL = live_url("EMBED_LIVE_BASE_URL").freeze
  LLM_CAPABILITIES = %i[tools vision documents streaming structured_output].freeze

  # One configured setup for every test: a cloud `openai` endpoint, a local `gpu`, an `embed`
  # server, a cloud `jev` and an external assistant (`agent`), with every feature routed.
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
      [ feature, names.map { |name| Ai::Route.new(feature:, model: lookup.fetch(name)) } ]
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

  # A transport that answers `generate`, `judge`, `embed` and `ocr` from the test, through Ai::Transport::Base,
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

      # The test answers the transcription, or nil for "page N" per page.
      def run_ocr(request)
        text = @responder.call(request) || request.pages.map { "transcribed #{_1.filename}" }.join("\n")
        OcrResponse.new(texts: [ text ], usage: Ai::Tokens.new(input_tokens: 100, output_tokens: 20))
      end

      # The test answers the vectors, or nil for one vector per text of the model's dimensions
      # (3 when it has none), each text's own so a search can tell them apart.
      def run_embed(request)
        vectors = @responder.call(request) || request.texts.map { AiTestHelper.vector_for(_1, request.model.embedding_dimensions || 3) }
        EmbedResponse.new(vectors: checked_vectors!(request.model, vectors),
                          usage: Ai::Tokens.new(input_tokens: 4 * request.texts.size, output_tokens: 0))
      end
  end

  # A stable unit vector per text, for embedding stubs.
  def self.vector_for(text, dimensions)
    seed = Digest::SHA256.digest(text.to_s).bytes
    raw = Array.new(dimensions) { |i| seed[i % seed.size] + 1.0 }
    norm = Math.sqrt(raw.sum { _1 * _1 })
    raw.map { _1 / norm }
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
      # flunk, not raise: a Minitest::Assertion gets past code under test that rescues StandardError.
      flunk "stub_ai(#{feature.inspect}) got a #{request.feature} request" if feature && request.feature != feature.to_sym

      requests << request
      raise raises if raises
      next block.call(request) if block

      returns.respond_to?(:call) ? returns.call(request) : returns
    end
    AiTestHelper.transport_stub = ->(endpoint) { FakeTransport.new(endpoint, responder) }
    requests
  end

  # Routes AI through the test setup for the rest of the test, with the named features' routes
  # replaced; the teardown restores the built config. Each call builds on the test's earlier
  # use_ai_routes and use_ai_model_settings.
  #   use_ai_routes
  #   use_ai_routes(categorize: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
  #   use_ai_routes(chat: [])   # chat :not_configured, everything else routed
  def use_ai_routes(vector_store_backend: :pgvector, **routes)
    base = ai_test_config
    use_ai_test_config(base.models, route_names(base).merge(routes), vector_store_backend:)
  end

  # Changes the test setup's models for the rest of the test, for budgets and the like, keeping the
  # routes an earlier use_ai_routes set: every model, or only the one named as use_ai_routes names it.
  #   use_ai_model_settings(batch_size: 2)
  #   use_ai_model_settings("gpu/qwen3-8b", batch_size: 2)
  def use_ai_model_settings(model = nil, **attributes)
    base = ai_test_config
    use_ai_test_config(changed_models(base, model, attributes), route_names(base), vector_store_backend: base.vector_store_backend)
  end

  # No AI configured for the rest of the test: every feature is :not_configured.
  def use_no_ai
    @ai_test_config = nil
    Ai::Config.override = Ai::Config.new
  end

  def ai_test_config = @ai_test_config || AiTestHelper.test_config

  def use_ai_test_config(models, routes, vector_store_backend:)
    @ai_test_config = Ai::Config.override = AiTestHelper.build_ai_config(models, routes, vector_store_backend:)
  end

  def route_names(config) = config.routes.transform_values { |list| list.map { "#{_1.endpoint.name}/#{_1.model.name}" } }

  def changed_models(config, model, attributes)
    named = config.models.map { "#{_1.endpoint.name}/#{_1.name}" }
    raise ArgumentError, "no #{model} in the test setup; it has #{named.join(", ")}" if model && named.exclude?(model)

    config.models.map { model.nil? || "#{_1.endpoint.name}/#{_1.name}" == model ? _1.with(**attributes) : _1 }
  end

  # A data URI's payload, as RubyLLM sends page images and PDFs.
  INLINE_FILE = %r{(data:[a-z]+/[a-z0-9.+-]+;base64,)[A-Za-z0-9+/=]+}

  AI_CASSETTE_KEYS = %w[OPENAI_ACCESS_TOKEN ANTHROPIC_API_KEY OPENROUTER_API_KEY LLAMA_CPP_API_KEY LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY
                        MISTRAL_LIVE_API_KEY COHERE_LIVE_API_KEY JEV_LIVE_API_KEY KILO_API_KEY KILO_ORG_ID
                        OPENROUTER_LIVE_API_KEY].freeze

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

  # Replays (or, with RECORD_CASSETTES=1 and the keys in ENV, records) a cassette under
  # test/vcr_cassettes/ai/<preset>/. Local servers listen on localhost, which Sure's VCR setup
  # ignores, so localhost is recorded inside the block only. Keys are filtered.
  #
  # With AI_LIVE=1 (the `ai-live` label's workflow) the block runs against the real provider
  # instead, with VCR off.
  # match: VCR matchers; :ai_model also compares the JSON body's `model`, so a replay can't pass
  # for a model the recording never asked for.
  def with_ai_cassette(preset, name, match: %i[method uri], &block)
    return with_ai_live(&block) if ENV["AI_LIVE"] == "1"

    recording = ENV["RECORD_CASSETTES"] == "1"
    path = "ai/#{preset}/#{name}"
    FileUtils.rm_f(Rails.root.join("test/vcr_cassettes/#{path}.yml")) if recording
    ignored = VCR.request_ignorer.localhost_ignored?   # restored, so a nested scope doesn't end the outer one's recording
    VCR.configuration.ignore_localhost = false
    VCR.use_cassette(path, record: recording ? :all : :none, match_requests_on: match, &block)
  ensure
    VCR.configuration.ignore_localhost = ignored unless ignored.nil?
  end

  # True when a live test can run: it's recording or live with its key (and, for a llama.cpp
  # server, the URL variable it uses), or replaying a cassette.
  def ai_cassette_available?(preset, name, key:, url: (preset.to_s == "llama_cpp" ? "LLAMA_CPP_URL" : nil))
    return ENV[key].present? && (url.nil? || ENV[url].present?) if AiTestHelper.live_or_recording?

    Rails.root.join("test/vcr_cassettes/ai/#{preset}/#{name}.yml").exist?
  end

  def with_ai_live
    raise ArgumentError, "with_ai_live needs AI_LIVE=1 or RECORD_CASSETTES=1" unless ENV["AI_LIVE"] == "1" || ENV["RECORD_CASSETTES"] == "1"

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
  # Recorded as placeholders, so a cassette replays whichever llama.cpp server the variable names.
  config.filter_sensitive_data("<LLAMA_CPP_URL>") { AiTestHelper::LLAMA_CPP_URL }
  config.filter_sensitive_data("<EMBED_URL>") { AiTestHelper::EMBED_URL }

  config.register_request_matcher(:ai_model) do |recorded, played|
    model = ->(request) { JSON.parse(request.body.to_s)["model"] rescue nil }
    model.(recorded) == model.(played)
  end

  # Page images and PDFs sent inline are kept out of cassettes: AI cassettes match on method and
  # URI, so the bytes add nothing on replay, and base64 can look like a credential to secret scans.
  # Anthropic sends them as bare base64 in `source.data` ("type": "base64"), not as data URIs.
  config.before_record do |interaction|
    body = interaction.request.body
    body = body.gsub(AiTestHelper::INLINE_FILE, '\\1<FILE>') if body&.match?(AiTestHelper::INLINE_FILE)
    body = AiTestHelper.redact_base64_sources(body) if body&.include?('"base64"')
    interaction.request.body = body
  end
end
