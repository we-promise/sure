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

  test "metadata mode shuts its tracer provider down at exit, so the last batch is exported" do
    provider = mock("tracer provider")
    Ai::Instrumentation::MetadataTracing.expects(:enable).with(endpoint: "https://otlp.example.test/v1/traces", headers: nil).returns(provider)
    provider.expects(:shutdown)
    Ai::Instrumentation.expects(:at_exit).yields

    Ai::Instrumentation.start_tracing!(env: { "OTLP_ENDPOINT" => "https://otlp.example.test/v1/traces" })
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

  test "a background call that found its model host busy is neither logged as a failure nor traced" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    occupied, release = Queue.new, Queue.new
    holder = Thread.new { Ai::Sequencer.gate_for(local).hold(:interactive) { occupied << true; release.pop } }
    occupied.pop(timeout: 2)
    request = Ai::Transport::Base::EmbedRequest.new(feature: :embed, family: nil, model: ai_model(endpoint: local, capabilities: %i[embedding]), texts: [ "a" ])
    log = []
    langfuse = Ai::Instrumentation::LangfuseSubscriber.new(client: FakeLangfuse.new(log))

    events = capture_ai_events do
      assert_no_difference "DebugLogEntry.count" do
        assert_raises(Ai::Error::Busy) { Ai::Sequencer.with_lane(:background) { Ai::Transport.for(local).embed(request) } }
      end
    end
    events.each { langfuse.call(_1) }

    assert_equal [ "Ai::Error::Busy" ], events.map { _1.payload[:error] }
    assert_empty log
  ensure
    release&.push(true)
    holder&.join(2)
  end

  test "a secret that contains another of the endpoint's secrets is masked whole" do
    scrubbed = Ai::Instrumentation::Redactor.scrub("tenant tenant-opaque-123-region-eu",
                                                   secrets: [ "tenant-opaque-123", "tenant-opaque-123-region-eu" ])

    assert_equal "tenant [REDACTED]", scrubbed
  end

  test "a literal + in a header value stays; %2B decodes to +" do
    assert_equal({ "Authorization" => "Basic ab+c/d==" },
                 Ai::Instrumentation::MetadataTracing.parse_headers("Authorization=Basic ab+c/d=="))
    assert_equal({ "x-team" => "a+b" }, Ai::Instrumentation::MetadataTracing.parse_headers("x-team=a%2Bb"))
  end

  private
    def event(name, payload)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications::Event.new(name, now - 1.5, now, SecureRandom.hex(4), payload)
    end
end
