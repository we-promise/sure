require "test_helper"
require "ostruct"

class LlmInstrumentationTest < ActiveSupport::TestCase
  class FakeSpan
    attr_reader :data, :status

    def initialize
      @data = {}
    end

    def set_data(key, value)
      @data[key] = value
    end

    def set_status(status)
      @status = status
    end

    def op
      "gen_ai.chat"
    end
  end

  test "with_gen_ai_span yields nil and returns block result when Sentry is not initialized" do
    Sentry.stubs(:initialized?).returns(false)

    result = LlmInstrumentation.with_gen_ai_span(operation: "chat", model: "gpt-4.1") do |span|
      assert_nil span
      "the response"
    end

    assert_equal "the response", result
  end

  test "with_gen_ai_span sets gen_ai attributes on the span" do
    fake_span = FakeSpan.new
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:with_child_span).yields(fake_span).returns(nil)

    LlmInstrumentation.with_gen_ai_span(operation: "chat", model: "gpt-4.1", system: "openai", conversation_id: "chat-123") { |_span| }

    assert_equal "chat", fake_span.data["gen_ai.operation.name"]
    assert_equal "gpt-4.1", fake_span.data["gen_ai.request.model"]
    assert_equal "openai", fake_span.data["gen_ai.system"]
    assert_equal "chat-123", fake_span.data["gen_ai.conversation.id"]
  end

  test "with_gen_ai_span marks span as errored and re-raises" do
    fake_span = FakeSpan.new
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:with_child_span).yields(fake_span).returns(nil)

    assert_raises(RuntimeError) do
      LlmInstrumentation.with_gen_ai_span(operation: "chat", model: "gpt-4.1") { raise "boom" }
    end

    assert_equal "internal_error", fake_span.status
  end

  test "add_span_usage maps the OpenAI Responses usage shape including cached and reasoning subsets" do
    span = FakeSpan.new

    LlmInstrumentation.add_span_usage(span, {
      "input_tokens" => 100,
      "output_tokens" => 40,
      "total_tokens" => 140,
      "input_tokens_details" => { "cached_tokens" => 90 },
      "output_tokens_details" => { "reasoning_tokens" => 10 }
    })

    assert_equal 100, span.data["gen_ai.usage.input_tokens"]
    assert_equal 40, span.data["gen_ai.usage.output_tokens"]
    assert_equal 140, span.data["gen_ai.usage.total_tokens"]
    assert_equal 90, span.data["gen_ai.usage.input_tokens.cached"]
    assert_equal 10, span.data["gen_ai.usage.output_tokens.reasoning"]
  end

  test "add_span_usage folds Anthropic cache tokens into the input total so cached stays a subset" do
    span = FakeSpan.new

    LlmInstrumentation.add_span_usage(span, {
      "input_tokens" => 10,
      "output_tokens" => 40,
      "cache_read_input_tokens" => 90,
      "cache_creation_input_tokens" => 20
    })

    # Sentry computes uncached = input - cached; a cached count larger than
    # the input total produces negative costs in the dashboard.
    assert_equal 120, span.data["gen_ai.usage.input_tokens"]
    assert_equal 90, span.data["gen_ai.usage.input_tokens.cached"]
    assert_equal 20, span.data["gen_ai.usage.input_tokens.cache_write"]
    assert_equal 160, span.data["gen_ai.usage.total_tokens"]
  end

  test "add_span_usage accumulates usage across batched calls" do
    span = FakeSpan.new

    LlmInstrumentation.add_span_usage(span, { "prompt_tokens" => 50, "completion_tokens" => 20 })
    LlmInstrumentation.add_span_usage(span, { "prompt_tokens" => 30, "completion_tokens" => 10 })

    assert_equal 80, span.data["gen_ai.usage.input_tokens"]
    assert_equal 30, span.data["gen_ai.usage.output_tokens"]
    assert_equal 110, span.data["gen_ai.usage.total_tokens"]
  end

  test "content capture is skipped unless send_default_pii is enabled" do
    span = FakeSpan.new
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:configuration).returns(OpenStruct.new(send_default_pii: false))

    LlmInstrumentation.set_span_input(span, "What is my net worth?", instructions: "You are a helpful assistant")
    LlmInstrumentation.set_span_output(span, "Your net worth is...")
    LlmInstrumentation.set_span_tool_call(span, arguments: { "a" => 1 }, result: { "b" => 2 })

    assert_empty span.data
  end

  test "content capture attaches messages in the Sentry conversation shape when PII capture is on" do
    span = FakeSpan.new
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:configuration).returns(OpenStruct.new(send_default_pii: true))

    LlmInstrumentation.set_span_input(
      span,
      [ { role: "user", content: "What is my net worth?" } ],
      instructions: "You are a helpful assistant"
    )
    LlmInstrumentation.set_span_output(span, "Your net worth is $1")

    input = JSON.parse(span.data["gen_ai.input.messages"])
    assert_equal [ { "role" => "user", "parts" => [ { "type" => "text", "content" => "What is my net worth?" } ] } ], input

    output = JSON.parse(span.data["gen_ai.output.messages"])
    assert_equal "assistant", output.first["role"]
    assert_equal "Your net worth is $1", output.first["parts"].first["content"]

    assert_equal "You are a helpful assistant", span.data["gen_ai.system_instructions"]
  end

  test "add_current_span_usage attaches usage to the active gen_ai span" do
    span = FakeSpan.new
    scope = OpenStruct.new(get_span: span)
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:get_current_scope).returns(scope)

    LlmInstrumentation.add_current_span_usage({ "input_tokens" => 5, "output_tokens" => 3 })

    assert_equal 5, span.data["gen_ai.usage.input_tokens"]
  end

  test "add_current_span_usage ignores non gen_ai spans" do
    span = OpenStruct.new(op: "http.client", data: {})
    scope = OpenStruct.new(get_span: span)
    Sentry.stubs(:initialized?).returns(true)
    Sentry.stubs(:get_current_scope).returns(scope)

    LlmInstrumentation.add_current_span_usage({ "input_tokens" => 5 })

    assert_empty span.data
  end
end
