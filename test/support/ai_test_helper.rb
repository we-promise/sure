# Helpers for testing AI code (ai-plumbing-redesign.md, section 17). 2a brings the transport
# level; 2b adds with_ai_routes and without_ai, 2c stub_ai, PR 3 with_ai_capsule.
module AiTestHelper
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
  def with_ai_cassette(preset, name, match: %i[method uri], &)
    recording = ENV["RECORD_CASSETTES"] == "1"
    path = "ai/#{preset}/#{name}"
    FileUtils.rm_f(Rails.root.join("test/vcr_cassettes/#{path}.yml")) if recording
    VCR.configuration.ignore_localhost = false
    VCR.use_cassette(path, record: recording ? :all : :none, match_requests_on: match, &)
  ensure
    VCR.configuration.ignore_localhost = true
  end
end

VCR.configure do |config|
  AiTestHelper::AI_CASSETTE_KEYS.each do |key|
    config.filter_sensitive_data("<#{key}>") { ENV[key].presence }
  end
end
