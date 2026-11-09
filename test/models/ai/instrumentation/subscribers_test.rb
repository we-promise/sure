require "test_helper"

class Ai::Instrumentation::SubscribersTest < ActiveSupport::TestCase
  FakeObservation = Struct.new(:log) do
    def generation(**attributes) = tap { log << [ :generation, attributes ] }
    def end(**attributes) = log << [ :end, attributes ]
  end

  FakeLangfuse = Struct.new(:log) do
    def trace(**attributes)
      log << [ :trace, attributes ]
      FakeObservation.new(log)
    end
  end

  test "the tracing mode follows the variables an operator already sets" do
    assert_equal :content, Ai::Instrumentation.mode(env: { "LANGFUSE_PUBLIC_KEY" => "pk", "LANGFUSE_SECRET_KEY" => "sk" })
    assert_equal :content, Ai::Instrumentation.mode(env: { "LANGFUSE_PUBLIC_KEY" => "pk", "LANGFUSE_SECRET_KEY" => "sk", "OTLP_ENDPOINT" => "http://otel:4318" })
    assert_equal :metadata, Ai::Instrumentation.mode(env: { "OTLP_ENDPOINT" => "http://otel:4318/v1/traces" })
    assert_equal :off, Ai::Instrumentation.mode(env: { "LANGFUSE_PUBLIC_KEY" => "pk" })
  end

  test "metadata mode shuts its tracer provider down at exit, so the last batch is exported" do
    provider = mock("tracer provider")
    Ai::Instrumentation::MetadataTracing.expects(:enable).with(endpoint: "https://otlp.example.test/v1/traces", headers: nil).returns(provider)
    provider.expects(:shutdown)
    Ai::Instrumentation.expects(:at_exit).yields

    Ai::Instrumentation.start_tracing!(env: { "OTLP_ENDPOINT" => "https://otlp.example.test/v1/traces" })
  end

  test "content mode subscribes Langfuse; the other modes don't" do
    content = Ai::Instrumentation.subscribe!(env: { "LANGFUSE_PUBLIC_KEY" => "pk", "LANGFUSE_SECRET_KEY" => "sk" })
    off = Ai::Instrumentation.subscribe!(env: {})

    assert_equal 5, content.size
    assert_equal 4, off.size
  ensure
    [ *content, *off ].each { ActiveSupport::Notifications.unsubscribe(_1) }
  end

  test "Langfuse gets one trace per call with the route and scrubbed output; probes aren't traced" do
    log = []
    subscriber = Ai::Instrumentation::LangfuseSubscriber.new(client: FakeLangfuse.new(log))
    payload = { feature: "bill_setup", call_id: "c1", route: { endpoint: "openai", model: "gpt-4.1" },
                request: { input: "charges" }, output: { name: "Netflix", notes: [ "billed with sk-live-abcdef123456" ] },
                usage: Ai::Tokens.new(input_tokens: 512, cache_read_tokens: 11_945, output_tokens: 20) }

    subscriber.call(event("generate.ai", payload))
    subscriber.call(event("probe.ai", payload))

    trace = log.find { _1.first == :trace }.last
    assert_equal "bill_setup.generate", trace[:name]
    generation_end = log.select { _1.first == :end }.first.last
    assert_equal({ input_tokens: 12_457, output_tokens: 20, prompt_tokens_details: { cached_tokens: 11_945 } }, generation_end[:usage])
    assert_equal 1, log.count { _1.first == :trace }, "probe.ai is skipped"
    ends = log.select { _1.first == :end }.map(&:last)
    assert_equal 2, ends.size, "the generation and the trace"
    ends.each { assert_equal({ name: "Netflix", notes: [ "billed with [REDACTED]" ] }, _1[:output]) }
  end

  test "Langfuse masks a field named like a credential, whatever its value looks like" do
    log = []
    subscriber = Ai::Instrumentation::LangfuseSubscriber.new(client: FakeLangfuse.new(log))
    payload = { feature: "bill_setup", call_id: "c1", route: { endpoint: "gateway", model: "m" },
                request: { input: "hi", options: { api_key: "opaque", "Authorization" => "opaque too" } }, output: { text: "ok" } }

    subscriber.call(event("generate.ai", payload))

    assert_equal({ input: "hi", options: { api_key: "[REDACTED]", "Authorization" => "[REDACTED]" } },
                 log.find { _1.first == :trace }.last[:input])
  end

  test "Langfuse content is scrubbed of the endpoint's own secrets, whatever their shape" do
    log = []
    subscriber = Ai::Instrumentation::LangfuseSubscriber.new(client: FakeLangfuse.new(log))
    scrub = ->(text) { Ai::Instrumentation::Redactor.scrub(text, secrets: [ "opaque-gateway-token" ]) }
    payload = { feature: "bill_setup", call_id: "c1", route: { endpoint: "gateway", model: "m" }, scrub:,
                request: { input: "use opaque-gateway-token" }, output: { text: "echo opaque-gateway-token" } }

    subscriber.call(event("generate.ai", payload))

    trace = log.find { _1.first == :trace }.last
    assert_equal({ input: "use [REDACTED]" }, trace[:input])
    assert_equal({ text: "echo [REDACTED]" }, log.find { _1.first == :end }.last[:output])
  end

  test "a failed call writes a debug log entry with its route and error, never its key" do
    payload = { feature: "categorize", call_id: "c1", family_id: families(:dylan_family).id,
                endpoint: { name: "gpu", protocol: :compatible }, route: { endpoint: "gpu", model: "qwen3-8b" },
                error: "Ai::Error::Upstream", error_message: "busy", http_status: 503 }

    assert_difference -> { DebugLogEntry.where(category: "ai").count }, 1 do
      Ai::Instrumentation::DebugLogSubscriber.new.call(ActiveSupport::Notifications::Event.new("generate.ai", nil, nil, "1", payload))
      Ai::Instrumentation::DebugLogSubscriber.new.call(ActiveSupport::Notifications::Event.new("probe.ai", nil, nil, "2", payload))
      Ai::Instrumentation::DebugLogSubscriber.new.call(ActiveSupport::Notifications::Event.new("generate.ai", nil, nil, "3", payload.except(:error)))
    end

    entry = DebugLogEntry.where(category: "ai").last
    assert_equal "error", entry.level
    assert_equal "gpu", entry.provider_key
    assert_equal families(:dylan_family), entry.family
    assert_equal "Ai::Error::Upstream", entry.metadata["error_class"]
    assert_equal({ "endpoint" => "gpu", "model" => "qwen3-8b" }, entry.metadata["route"])
  end

  test "the redactor masks key shapes, authorization values and the endpoint's own key" do
    text = "key sk-proj-abcdefghijkl Bearer abc.def.ghi123 api_key=hunter22hunter custom-secret-value"

    scrubbed = Ai::Instrumentation::Redactor.scrub(text, secrets: [ "custom-secret-value" ])

    %w[sk-proj-abcdefghijkl abc.def.ghi123 hunter22hunter custom-secret-value].each { assert_not_includes scrubbed, _1 }
    assert_includes scrubbed, "Bearer [REDACTED]"
    assert_includes scrubbed, "api_key=[REDACTED]"
  end

  test "a secret that contains another of the endpoint's secrets is masked whole" do
    scrubbed = Ai::Instrumentation::Redactor.scrub("tenant tenant-opaque-123-region-eu",
                                                   secrets: [ "tenant-opaque-123", "tenant-opaque-123-region-eu" ])

    assert_equal "tenant [REDACTED]", scrubbed
  end

  private
    def event(name, payload)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications::Event.new(name, now - 1.5, now, SecureRandom.hex(4), payload)
    end
end
