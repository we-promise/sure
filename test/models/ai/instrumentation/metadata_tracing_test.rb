require "test_helper"

# `metadata` mode must never send content: no prompt, answer, tool result or error body on any
# span. RubyLLM 2.2 can put content on spans when asked (RubyLLM #1333), so this test guards upgrades.
class Ai::Instrumentation::MetadataTracingTest < ActiveSupport::TestCase
  URL = "https://llm.example.test/v1/chat/completions".freeze
  SECRET_PROMPT = "Reply with OK.".freeze
  SECRET_ANSWER = "NETFLIX-CHARGE-15.49".freeze

  setup do
    @previous_provider = OpenTelemetry.tracer_provider
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    Ai::Instrumentation::MetadataTracing.enable(processor: OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
    @model = ai_model(name: "test-model")
  end

  teardown do
    RubyLLM::OpenTelemetry.disable
    OpenTelemetry.tracer_provider = @previous_provider
  end

  test "spans carry the model, tokens and session, and none of the content" do
    stub_request(:post, URL).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: SECRET_ANSWER }, finish_reason: "stop" } ],
      usage: { prompt_tokens: 9, completion_tokens: 4, total_tokens: 13 }
    }.to_json)

    Ai::CallContext.job("sync:99") { chat_call }

    spans = @exporter.finished_spans
    chat = spans.find { _1.attributes["gen_ai.operation.name"] == "chat" }
    assert chat, "a chat span: #{spans.map(&:name)}"
    assert_equal "test-model", chat.attributes["gen_ai.request.model"]
    assert_equal "sync:99", chat.attributes["session.id"]

    everything = spans.flat_map { [ _1.name, _1.attributes.to_a, _1.events.to_a.map { |e| [ e.name, e.attributes.to_a ] }, _1.status.description ] }.to_s
    assert_not_includes everything, SECRET_PROMPT
    assert_not_includes everything, SECRET_ANSWER
  end

  test "an error body never reaches a span" do
    stub_request(:post, URL).to_return(status: 500, headers: { "Content-Type" => "application/json" },
                                       body: { error: { message: "failed on #{SECRET_ANSWER}" } }.to_json)

    assert_raises(Ai::Error::Upstream) { chat_call }

    assert @exporter.finished_spans.any? { _1.attributes["gen_ai.operation.name"] == "chat" && _1.attributes["error.type"].present? },
           "a failed chat span: #{@exporter.finished_spans.map { [ _1.name, _1.attributes ] }}"
    assert_not_includes @exporter.finished_spans.map { [ _1.attributes.to_a, _1.events.to_a.map(&:attributes), _1.status.description ] }.to_s, SECRET_ANSWER
  end

  test "health probes aren't traced; the calls around them are" do
    stub_request(:post, URL).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ]
    }.to_json)

    Ai::Transport.for(@model.endpoint).probe(@model, :chat)
    assert_empty @exporter.finished_spans

    chat_call
    assert @exporter.finished_spans.any? { _1.attributes["gen_ai.operation.name"] == "chat" }
  end

  test "OTLP_HEADERS takes the OpenTelemetry key=value form" do
    assert_equal({ "Authorization" => "Basic abc=", "x-team" => "home" },
                 Ai::Instrumentation::MetadataTracing.parse_headers("Authorization=Basic%20abc%3D, x-team=home"))
  end

  test "a literal + in a header value stays; %2B decodes to +" do
    assert_equal({ "Authorization" => "Basic ab+c/d==" },
                 Ai::Instrumentation::MetadataTracing.parse_headers("Authorization=Basic ab+c/d=="))
    assert_equal({ "x-team" => "a+b" }, Ai::Instrumentation::MetadataTracing.parse_headers("x-team=a%2Bb"))
  end

  private
    # A chat request inside a feature's call, as a generation makes it.
    def chat_call
      Ai::CallContext.call(feature: :bill_setup, model: @model) { Ai::Transport.for(@model.endpoint).send(:probe_chat, @model) }
    end
end
