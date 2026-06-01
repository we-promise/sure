require "test_helper"
require "ostruct"

class Provider::AnthropicTest < ActiveSupport::TestCase
  include LLMInterfaceTest

  setup do
    @subject = @anthropic = Provider::Anthropic.new(
      ENV.fetch("ANTHROPIC_API_KEY", "test-anthropic-token")
    )
    @subject_model = "claude-sonnet-4-6"
  end

  test "provider_name returns Anthropic for standard provider" do
    assert_equal "Anthropic", @subject.provider_name
  end

  test "provider_name returns custom info for custom base_url" do
    custom = Provider::Anthropic.new(
      "test-token",
      base_url: "https://bedrock.example.com/anthropic",
      model: "claude-opus-4-7"
    )

    assert_equal "Custom Anthropic-compatible (https://bedrock.example.com/anthropic)", custom.provider_name
  end

  test "supports_model? returns true for claude prefix" do
    assert @subject.supports_model?("claude-sonnet-4-6")
    assert @subject.supports_model?("claude-opus-4-7")
    assert @subject.supports_model?("claude-haiku-4-5")
    assert_not @subject.supports_model?("gpt-4.1")
  end

  test "supports_model? bypasses the prefix gate for custom endpoints" do
    custom = Provider::Anthropic.new(
      "test-token",
      base_url: "https://bedrock.example.com/anthropic",
      model: "anthropic.claude-sonnet-4-5-20250929-v1:0"
    )

    # Bedrock-shaped IDs start with "anthropic", not "claude" — would fail the
    # default prefix check, but custom endpoints must accept any model.
    assert custom.supports_model?("anthropic.claude-sonnet-4-5-20250929-v1:0")
    assert custom.supports_model?("claude-opus-4@20250514")
    assert custom.supports_model?("any-string-the-endpoint-accepts")
  end

  test "supported_models_description returns prefixes for standard provider" do
    assert_equal "models starting with: claude", @subject.supported_models_description
  end

  test "supports_pdf_processing? true for claude models" do
    assert @subject.supports_pdf_processing?(model: "claude-sonnet-4-6")
    assert_not @subject.supports_pdf_processing?(model: "gpt-4o")
  end

  test "effective_model defers to ENV when set without consulting Setting" do
    ClimateControl.modify("ANTHROPIC_MODEL" => "claude-haiku-4-5") do
      Setting.expects(:anthropic_model).never
      assert_equal "claude-haiku-4-5", Provider::Anthropic.effective_model
    end
  end

  test "configured? reflects ENV and Setting presence" do
    ClimateControl.modify("ANTHROPIC_ACCESS_TOKEN" => nil, "ANTHROPIC_API_KEY" => nil) do
      Setting.stubs(:anthropic_access_token).returns(nil)
      assert_not Provider::Anthropic.configured?

      Setting.stubs(:anthropic_access_token).returns("fake-token-1")
      assert Provider::Anthropic.configured?
    end

    ClimateControl.modify("ANTHROPIC_API_KEY" => "fake-token-2") do
      Setting.stubs(:anthropic_access_token).returns(nil)
      assert Provider::Anthropic.configured?
    end
  end

  test "effective_model falls back to default when nothing set" do
    ClimateControl.modify("ANTHROPIC_MODEL" => nil) do
      Setting.stubs(:anthropic_model).returns(nil)
      assert_equal Provider::Anthropic::DEFAULT_MODEL, Provider::Anthropic.effective_model
    end
  end

  test "chat_response wraps Anthropic SDK errors in Provider::Anthropic::Error" do
    fake_client = mock
    @subject.instance_variable_set(:@client, fake_client)
    messages = mock
    fake_client.stubs(:messages).returns(messages)
    messages.expects(:create).raises(StandardError.new("rate limit exceeded"))

    response = @subject.chat_response("hi", model: @subject_model)

    assert_not response.success?
    assert_kind_of Provider::Anthropic::Error, response.error
    assert_match(/rate limit/i, response.error.message)
  end

  test "chat_response accepts messages: kwarg passed by Responder without raising" do
    # The OpenAI-shaped `messages:` array is passed alongside `conversation_history:`
    # for cross-provider parity. Anthropic ignores it but must still accept it as
    # a keyword argument — historical regression that broke the first chat turn.
    fake_client = stub_anthropic_client_with(
      build_anthropic_message(
        id: "msg_kw",
        model: @subject_model,
        text_blocks: [ "ok" ],
        tool_use_blocks: [],
        usage: { input_tokens: 1, output_tokens: 1 }
      )
    )
    @subject.instance_variable_set(:@client, fake_client)

    response = @subject.chat_response(
      "hi",
      model: @subject_model,
      messages: [ { role: "user", content: "hi" } ],
      conversation_history: []
    )

    assert response.success?
  end

  test "chat_response returns parsed ChatResponse on success" do
    fake_client = stub_anthropic_client_with(
      build_anthropic_message(
        id: "msg_abc",
        model: @subject_model,
        text_blocks: [ "Hello there." ],
        tool_use_blocks: [],
        usage: { input_tokens: 12, output_tokens: 5 }
      )
    )
    @subject.instance_variable_set(:@client, fake_client)

    response = @subject.chat_response("hi", model: @subject_model)

    assert response.success?
    assert_equal "msg_abc", response.data.id
    assert_equal @subject_model, response.data.model
    assert_equal 1, response.data.messages.size
    assert_equal "Hello there.", response.data.messages.first.output_text
    assert_empty response.data.function_requests
  end

  test "chat_response streams text deltas and emits a final response chunk" do
    final_message = build_anthropic_message(
      id: "msg_stream",
      model: @subject_model,
      text_blocks: [ "Hello world" ],
      tool_use_blocks: [],
      usage: { input_tokens: 7, output_tokens: 3 }
    )
    # Use ad-hoc subclasses of the SDK event types so the case/when dispatch
    # inside `stream_chat_response` matches them via `is_a?` without needing
    # to stub class-level `===` behavior.
    text_event_cls = Class.new(::Anthropic::Streaming::TextEvent) do
      def initialize(text:, snapshot:)
        @text = text
        @snapshot = snapshot
      end
      attr_reader :text, :snapshot
    end
    stop_event_cls = Class.new(::Anthropic::Streaming::MessageStopEvent) do
      def initialize(message:)
        @message = message
      end
      attr_reader :message
    end
    events = [
      text_event_cls.new(text: "Hello ", snapshot: "Hello "),
      text_event_cls.new(text: "world", snapshot: "Hello world"),
      stop_event_cls.new(message: final_message)
    ]

    fake_stream = mock
    fake_stream.stubs(:each).multiple_yields(*events.map { |e| [ e ] })
    fake_stream.stubs(:accumulated_message).returns(final_message)

    messages = mock
    messages.stubs(:stream).returns(fake_stream)
    client = mock
    client.stubs(:messages).returns(messages)
    @subject.instance_variable_set(:@client, client)

    collected = []
    response = @subject.chat_response(
      "hi",
      model: @subject_model,
      streamer: ->(chunk) { collected << chunk }
    )

    assert response.success?
    text_chunks = collected.select { |c| c.type == "output_text" }
    response_chunks = collected.select { |c| c.type == "response" }

    assert_equal 2, text_chunks.size
    assert_equal [ "Hello ", "world" ], text_chunks.map(&:data)
    assert_equal 1, response_chunks.size
    assert_equal "msg_stream", response_chunks.first.data.id
    assert_equal 10, response_chunks.first.usage["total_tokens"]
  end

  test "chat_response surfaces tool_use blocks as function_requests" do
    fake_client = stub_anthropic_client_with(
      build_anthropic_message(
        id: "msg_xyz",
        model: @subject_model,
        text_blocks: [],
        tool_use_blocks: [ { id: "toolu_1", name: "get_net_worth", input: { currency: "USD" } } ],
        usage: { input_tokens: 20, output_tokens: 8 }
      )
    )
    @subject.instance_variable_set(:@client, fake_client)

    response = @subject.chat_response(
      "What is my net worth?",
      model: @subject_model,
      functions: [ {
        name: "get_net_worth",
        description: "Gets a user's net worth",
        params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
        strict: true
      } ]
    )

    assert response.success?
    assert_equal 1, response.data.function_requests.size

    req = response.data.function_requests.first
    assert_equal "toolu_1", req.call_id
    assert_equal "get_net_worth", req.function_name
    assert_equal({ currency: "USD" }.to_json, req.function_args)
  end

  private
    def stub_anthropic_client_with(message)
      messages = mock
      messages.stubs(:create).returns(message)
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def build_anthropic_message(id:, model:, text_blocks:, tool_use_blocks:, usage:)
      OpenStruct.new(
        id: id,
        model: model,
        content: text_blocks.map { |t| OpenStruct.new(type: :text, text: t) } +
                 tool_use_blocks.map { |t| OpenStruct.new(type: :tool_use, id: t[:id], name: t[:name], input: t[:input]) },
        usage: OpenStruct.new(
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens]
        )
      )
    end
end
