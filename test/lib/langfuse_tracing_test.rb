require "test_helper"

class LangfuseTracingTest < ActiveSupport::TestCase
  setup do
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @client = LangfuseTracing.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test",
      processor: OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
  end

  teardown do
    @client.shutdown
  end

  test "exports complete observations once with root IO and context on every child" do
    root = @client.trace(name: "openai.chat_response", input: { prompt: "Hello" }, session_id: "chat-1",
      user_id: "hashed-user", environment: "test", metadata: { workflow: "chat" }, attributes: {
        "langfuse.trace.tags" => [ "canary" ], "langfuse.version" => "1", "langfuse.release" => "commit", "langfuse.trace.public" => false
      })
    generation = root.generation(name: "chat_response", model: "gpt-4.1", input: "Hello")
    tool = root.span(name: "tool", input: "query")
    assert_empty @exporter.finished_spans

    generation.end(output: "Hi", usage: { "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15 })
    tool.end(output: "result")
    root.end(output: "Hi")
    root.end(output: "duplicate")

    spans = @exporter.finished_spans
    assert_equal 3, spans.size
    assert_equal 1, spans.map(&:trace_id).uniq.size
    root_span = spans.find { |span| span.name == "openai.chat_response" }
    assert_equal({ "prompt" => "Hello" }, JSON.parse(root_span.attributes["langfuse.observation.input"]))
    assert_equal "Hi", JSON.parse(root_span.attributes["langfuse.observation.output"])
    assert root_span.attributes["langfuse.internal.as_root"]

    spans.each do |span|
      assert_equal "chat-1", span.attributes["langfuse.session.id"]
      assert_equal "hashed-user", span.attributes["langfuse.user.id"]
      assert_equal "test", span.attributes["langfuse.environment"]
      assert_equal "openai.chat_response", span.attributes["langfuse.trace.name"]
      assert_equal "chat", span.attributes["langfuse.trace.metadata.workflow"]
      assert_equal [ "canary" ], span.attributes["langfuse.trace.tags"]
      assert_equal "1", span.attributes["langfuse.version"]
      assert_equal "commit", span.attributes["langfuse.release"]
      assert_equal false, span.attributes["langfuse.trace.public"]
      refute span.attributes.key?("langfuse.trace.input")
      refute span.attributes.key?("langfuse.trace.output")
      assert_equal root_span.span_id, span.parent_span_id unless span == root_span
    end

    llm_span = spans.find { |span| span.name == "chat_response" }
    assert_equal "generation", llm_span.attributes["langfuse.observation.type"]
    assert_equal "gpt-4.1", llm_span.attributes["langfuse.observation.model.name"]
    assert_equal({ "input" => 10, "output" => 5, "total" => 15 }, JSON.parse(llm_span.attributes["langfuse.observation.usage_details"]))
  end

  test "keeps separate sessions isolated and records errors" do
    first = @client.trace(name: "first", input: "one", session_id: "session-one")
    second = @client.trace(name: "second", input: "two", session_id: "session-two")
    first.end(output: { error: "failed" }, level: "ERROR")
    second.end(output: "ok")

    failed, succeeded = @exporter.finished_spans
    assert_equal "session-one", failed.attributes["langfuse.session.id"]
    assert_equal "session-two", succeeded.attributes["langfuse.session.id"]
    refute_equal failed.trace_id, succeeded.trace_id
    assert_equal OpenTelemetry::Trace::Status::ERROR, failed.status.code
    assert_equal "ERROR", failed.attributes["langfuse.observation.level"]
  end

  test "normalizes OpenAI cached tokens without counting them twice" do
    root = @client.trace(name: "chat", input: "prompt")
    root.generation(name: "chat", input: "prompt", model: "gpt-4.1").end(output: "answer", usage: {
      "prompt_tokens" => 100, "completion_tokens" => 20, "total_tokens" => 120,
      "prompt_tokens_details" => { "cached_tokens" => 60 }
    })
    usage = JSON.parse(@exporter.finished_spans.first.attributes["langfuse.observation.usage_details"])
    assert_equal 40, usage["input"]
    assert_equal 60, usage["input_cached_tokens"]
    assert_equal 120, usage["total"]
    root.end
  end

  test "preserves Anthropic cache usage and original request timing" do
    start_time = 2.seconds.ago
    root = @client.trace(name: "chat", input: "prompt", start_time: start_time)
    root.generation(name: "chat", input: "prompt", model: "claude-sonnet-4-6", start_time: root.start_time).end(output: "answer", usage: {
      "input_tokens" => 10, "output_tokens" => 20, "cache_read_input_tokens" => 50, "cache_creation_input_tokens" => 30
    })
    span = @exporter.finished_spans.first
    usage = JSON.parse(span.attributes["langfuse.observation.usage_details"])
    assert_equal 10, usage["input"]
    assert_equal 50, usage["cache_read_input_tokens"]
    assert_equal 30, usage["cache_creation_input_tokens"]
    assert_equal 110, usage["total"]
    assert_in_delta start_time.to_f, span.start_timestamp / 1_000_000_000.0, 0.001
    root.end
  end

  test "flush sends OTLP to the configured host with v4 authentication headers" do
    request = stub_request(:post, "https://langfuse.test/api/public/otel/v1/traces")
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('pk-test:sk-test')}", "x-langfuse-ingestion-version" => "4" })
      .to_return(status: 200, body: "")
    client = LangfuseTracing.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test/")
    client.trace(name: "request", input: "prompt").end(output: "response")
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, client.flush
    assert_requested request, times: 1
  ensure
    client&.shutdown
  end

  test "provider failures finish their roots without changing the provider response" do
    Rails.configuration.x.stubs(:langfuse).returns(@client)
    with_env_overrides("LANGFUSE_PUBLIC_KEY" => "pk-test", "LANGFUSE_SECRET_KEY" => "sk-test") do
      [ Provider::Openai, Provider::Anthropic ].each do |provider_class|
        provider_class::AutoCategorizer.any_instance.stubs(:auto_categorize).raises(StandardError, "LLM unavailable")
        response = provider_class.new("test-token").auto_categorize(
          transactions: [ { id: "transaction", description: "Coffee" } ], user_categories: [ { id: "category", name: "Dining" } ])
        refute response.success?
        assert_equal "LLM unavailable", response.error.message
      end
    end
    assert_equal 2, @exporter.finished_spans.size
    @exporter.finished_spans.each do |span|
      assert_equal "ERROR", span.attributes["langfuse.observation.level"]
      assert_equal({ "error" => "LLM unavailable" }, JSON.parse(span.attributes["langfuse.observation.output"]))
    end
  end

  test "shutdown flushes pending observations and a failed flush reports failure" do
    request = stub_request(:post, "https://langfuse.test/api/public/otel/v1/traces").to_return(status: 401)
    client = LangfuseTracing.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test")
    client.trace(name: "request", input: "prompt").end(output: "response")
    assert_equal OpenTelemetry::SDK::Trace::Export::FAILURE, client.flush
    request.to_return(status: 200, body: "")
    client.trace(name: "second", input: "prompt").end(output: "response")
    client.shutdown
    assert_requested request, times: 2
  end

  test "tracing finalization failures preserve the original provider error" do
    [ Provider::Openai, Provider::Anthropic ].each do |provider_class|
      original_error = provider_class::Error.new("LLM unavailable", failure_code: :provider_unavailable)
      provider_class::AutoCategorizer.any_instance.stubs(:auto_categorize).raises(original_error)
      trace = mock
      trace.expects(:end).with(output: { error: "LLM unavailable" }, level: "ERROR").raises(StandardError, "Tracing unavailable")
      provider = provider_class.new("test-token")
      provider.stubs(:create_langfuse_trace).returns(trace)
      Rails.logger.expects(:warn).with("Langfuse trace finalization failed: StandardError: Tracing unavailable")

      response = provider.auto_categorize(transactions: [ { id: "transaction", description: "Coffee" } ],
        user_categories: [ { id: "category", name: "Dining" } ])

      refute response.success?
      assert_equal original_error.message, response.error.message
      assert_equal :provider_unavailable, response.error.failure_code
    end
  end
end
