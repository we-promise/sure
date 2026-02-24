require "test_helper"

class AssistantTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @chat = chats(:two)
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "What is my net worth?",
      ai_model: "gpt-4.1"
    )
    @assistant = Assistant.for_chat(@chat)
    @provider = mock
    @expected_session_id = @chat.id.to_s
    @expected_user_identifier = ::Digest::SHA256.hexdigest(@chat.user_id.to_s)
  end

  test "errors get added to chat" do
    @assistant.expects(:get_model_provider).with("gpt-4.1").returns(@provider)

    error = StandardError.new("test error")
    @provider.expects(:chat_response).returns(provider_error_response(error))

    @chat.expects(:add_error).with(error).once

    assert_no_difference "AssistantMessage.count"  do
      @assistant.respond_to(@message)
    end
  end

  test "handles missing provider gracefully with helpful error message" do
    # Simulate no provider configured (returns nil)
    @assistant.expects(:get_model_provider).with("gpt-4.1").returns(nil)

    # Mock the registry to return empty providers
    mock_registry = mock("registry")
    mock_registry.stubs(:providers).returns([])
    @assistant.stubs(:registry).returns(mock_registry)

    @chat.expects(:add_error).with do |error|
      assert_includes error.message, "No LLM provider configured that supports model 'gpt-4.1'"
      assert_includes error.message, "Please configure an LLM provider (e.g., OpenAI) in settings."
      true
    end

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "shows available providers in error message when model not supported" do
    # Simulate provider exists but doesn't support the model
    @assistant.expects(:get_model_provider).with("claude-3").returns(nil)

    # Create mock provider
    mock_provider = mock("openai_provider")
    mock_provider.stubs(:provider_name).returns("OpenAI")
    mock_provider.stubs(:supported_models_description).returns("models starting with: gpt-4, gpt-5, o1, o3")

    # Mock the registry to return the provider
    mock_registry = mock("registry")
    mock_registry.stubs(:providers).returns([ mock_provider ])
    @assistant.stubs(:registry).returns(mock_registry)

    # Update message to use unsupported model
    @message.update!(ai_model: "claude-3")

    @chat.expects(:add_error).with do |error|
      assert_includes error.message, "No LLM provider configured that supports model 'claude-3'"
      assert_includes error.message, "Available providers:"
      assert_includes error.message, "OpenAI: models starting with: gpt-4, gpt-5, o1, o3"
      assert_includes error.message, "Use a supported model from the list above"
      true
    end

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "responds to basic prompt" do
    @assistant.expects(:get_model_provider).with("gpt-4.1").returns(@provider)

    text_chunks = [
      provider_text_chunk("I do not "),
      provider_text_chunk("have the information "),
      provider_text_chunk("to answer that question")
    ]

    response_chunk = provider_response_chunk(
      id: "1",
      model: "gpt-4.1",
      messages: [ provider_message(id: "1", text: text_chunks.join) ],
      function_requests: []
    )

    response = provider_success_response(response_chunk.data)

    @provider.expects(:chat_response).with do |message, **options|
      assert_equal @expected_session_id, options[:session_id]
      assert_equal @expected_user_identifier, options[:user_identifier]
      text_chunks.each do |text_chunk|
        options[:streamer].call(text_chunk)
      end

      options[:streamer].call(response_chunk)
      true
    end.returns(response)

    assert_difference "AssistantMessage.count", 1 do
      @assistant.respond_to(@message)
      message = @chat.messages.ordered.where(type: "AssistantMessage").last
      assert_equal "I do not have the information to answer that question", message.content
      assert_equal 0, message.tool_calls.size
    end
  end

  test "responds with tool function calls" do
    @assistant.expects(:get_model_provider).with("gpt-4.1").returns(@provider).once

    # Only first provider call executes function
    Assistant::Function::GetAccounts.any_instance.stubs(:call).returns("test value").once

    # Call #1: Function requests
    call1_response_chunk = provider_response_chunk(
      id: "1",
      model: "gpt-4.1",
      messages: [],
      function_requests: [
        provider_function_request(id: "1", call_id: "1", function_name: "get_accounts", function_args: "{}")
      ]
    )

    call1_response = provider_success_response(call1_response_chunk.data)

    # Call #2: Text response (that uses function results)
    call2_text_chunks = [
      provider_text_chunk("Your net worth is "),
      provider_text_chunk("$124,200")
    ]

    call2_response_chunk = provider_response_chunk(
      id: "2",
      model: "gpt-4.1",
      messages: [ provider_message(id: "1", text: call2_text_chunks.join) ],
      function_requests: []
    )

    call2_response = provider_success_response(call2_response_chunk.data)

    sequence = sequence("provider_chat_response")

    @provider.expects(:chat_response).with do |message, **options|
      assert_equal @expected_session_id, options[:session_id]
      assert_equal @expected_user_identifier, options[:user_identifier]
      call2_text_chunks.each do |text_chunk|
        options[:streamer].call(text_chunk)
      end

      options[:streamer].call(call2_response_chunk)
      true
    end.returns(call2_response).once.in_sequence(sequence)

    @provider.expects(:chat_response).with do |message, **options|
      assert_equal @expected_session_id, options[:session_id]
      assert_equal @expected_user_identifier, options[:user_identifier]
      options[:streamer].call(call1_response_chunk)
      true
    end.returns(call1_response).once.in_sequence(sequence)

    assert_difference "AssistantMessage.count", 1 do
      @assistant.respond_to(@message)
      message = @chat.messages.ordered.where(type: "AssistantMessage").last
      assert_equal 1, message.tool_calls.size
    end
  end

  test "for_chat returns Builtin by default" do
    assert_instance_of Assistant::Builtin, Assistant.for_chat(@chat)
  end

  test "available_types includes builtin and external" do
    assert_includes Assistant.available_types, "builtin"
    assert_includes Assistant.available_types, "external"
  end

  test "for_chat returns External when family assistant_type is external" do
    @chat.user.family.update!(assistant_type: "external")
    assert_instance_of Assistant::External, Assistant.for_chat(@chat)
  end

  test "ASSISTANT_TYPE env override forces external regardless of DB value" do
    assert_equal "builtin", @chat.user.family.assistant_type

    with_env_overrides("ASSISTANT_TYPE" => "external") do
      assert_instance_of Assistant::External, Assistant.for_chat(@chat)
    end

    assert_instance_of Assistant::Builtin, Assistant.for_chat(@chat)
  end

  test "external assistant responds with streamed text" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    sse_body = <<~SSE
      data: {"choices":[{"delta":{"content":"Your net worth"}}],"model":"openclaw:buster"}

      data: {"choices":[{"delta":{"content":" is $124,200."}}],"model":"openclaw:buster"}

      data: [DONE]

    SSE

    mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assert_difference "AssistantMessage.count", 1 do
        assistant.respond_to(@message)
      end

      response_msg = @chat.messages.where(type: "AssistantMessage").last
      assert_equal "Your net worth is $124,200.", response_msg.content
      assert_equal "openclaw:buster", response_msg.ai_model
    end
  end

  test "external assistant adds error when not configured" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => nil,
      "EXTERNAL_ASSISTANT_TOKEN" => nil
    ) do
      assert_no_difference "AssistantMessage.count" do
        assistant.respond_to(@message)
      end

      @chat.reload
      assert @chat.error.present?
      assert_includes @chat.error, "not configured"
    end
  end

  test "external assistant adds error on connection failure" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    Net::HTTP.any_instance.stubs(:request).raises(Errno::ECONNREFUSED, "Connection refused")

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assert_no_difference "AssistantMessage.count" do
        assistant.respond_to(@message)
      end

      @chat.reload
      assert @chat.error.present?
    end
  end

  test "external assistant handles empty response gracefully" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    sse_body = <<~SSE
      data: {"choices":[{"delta":{"role":"assistant"}}],"model":"openclaw:buster"}

      data: {"choices":[{"delta":{}}],"model":"openclaw:buster"}

      data: [DONE]

    SSE

    mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assert_no_difference "AssistantMessage.count" do
        assistant.respond_to(@message)
      end

      @chat.reload
      assert @chat.error.present?
      assert_includes @chat.error, "empty response"
    end
  end

  test "external assistant sends conversation history" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    AssistantMessage.create!(chat: @chat, content: "I can help with that.", ai_model: "external")

    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"Sure!\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assistant.respond_to(@message)

      body = JSON.parse(capture[0].body)
      messages = body["messages"]

      assert messages.size >= 2
      assert_equal "user", messages.first["role"]
    end
  end

  test "full external assistant flow: config check, stream, save, error recovery" do
    @chat.user.family.update!(assistant_type: "external")

    # Phase 1: Without config, errors gracefully
    with_env_overrides("EXTERNAL_ASSISTANT_URL" => nil, "EXTERNAL_ASSISTANT_TOKEN" => nil) do
      assistant = Assistant::External.new(@chat)
      assistant.respond_to(@message)
      @chat.reload
      assert @chat.error.present?
    end

    # Phase 2: With config, streams response
    @chat.update!(error: nil)

    sse_body = <<~SSE
      data: {"choices":[{"delta":{"content":"Based on your accounts, "}}],"model":"openclaw:buster"}

      data: {"choices":[{"delta":{"content":"your net worth is $50,000."}}],"model":"openclaw:buster"}

      data: [DONE]

    SSE

    mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://openclaw:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "oc_test123"
    ) do
      assistant = Assistant::External.new(@chat)
      assistant.respond_to(@message)

      @chat.reload
      assert_nil @chat.error

      response = @chat.messages.where(type: "AssistantMessage").last
      assert_equal "Based on your accounts, your net worth is $50,000.", response.content
      assert_equal "openclaw:buster", response.ai_model
    end
  end

  test "ASSISTANT_TYPE env override with unknown value falls back to builtin" do
    with_env_overrides("ASSISTANT_TYPE" => "nonexistent") do
      assert_instance_of Assistant::Builtin, Assistant.for_chat(@chat)
    end
  end

  test "external assistant sets user identifier with family_id" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}],\"model\":\"m\"}\n\ndata: [DONE]\n\n"
    capture = mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assistant.respond_to(@message)

      body = JSON.parse(capture[0].body)
      assert_equal "sure-family-#{@chat.user.family_id}", body["user"]
    end
  end

  test "external assistant updates ai_model from SSE response model field" do
    @chat.user.family.update!(assistant_type: "external")
    assistant = Assistant.for_chat(@chat)

    sse_body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}],\"model\":\"openclaw:custom-agent\"}\n\ndata: [DONE]\n\n"
    mock_external_sse_response(sse_body)

    with_env_overrides(
      "EXTERNAL_ASSISTANT_URL" => "http://localhost:18789/v1/chat/completions",
      "EXTERNAL_ASSISTANT_TOKEN" => "test-token"
    ) do
      assistant.respond_to(@message)

      response = @chat.messages.where(type: "AssistantMessage").last
      assert_equal "openclaw:custom-agent", response.ai_model
    end
  end

  test "for_chat raises when chat is blank" do
    assert_raises(Assistant::Error) { Assistant.for_chat(nil) }
  end

  private

    def mock_external_sse_response(sse_body)
      capture = []
      mock_response = stub("response")
      mock_response.stubs(:code).returns("200")
      mock_response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
      mock_response.stubs(:read_body).yields(sse_body)

      mock_http = stub("http")
      mock_http.stubs(:use_ssl=)
      mock_http.stubs(:open_timeout=)
      mock_http.stubs(:read_timeout=)
      mock_http.stubs(:request).with do |req|
        capture[0] = req
        true
      end.yields(mock_response)

      Net::HTTP.stubs(:new).returns(mock_http)
      capture
    end

    def provider_function_request(id:, call_id:, function_name:, function_args:)
      Provider::LlmConcept::ChatFunctionRequest.new(
        id: id,
        call_id: call_id,
        function_name: function_name,
        function_args: function_args
      )
    end

    def provider_message(id:, text:)
      Provider::LlmConcept::ChatMessage.new(id: id, output_text: text)
    end

    def provider_text_chunk(text)
      Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text, usage: nil)
    end

    def provider_response_chunk(id:, model:, messages:, function_requests:, usage: nil)
      Provider::LlmConcept::ChatStreamChunk.new(
        type: "response",
        data: Provider::LlmConcept::ChatResponse.new(
          id: id,
          model: model,
          messages: messages,
          function_requests: function_requests
        ),
        usage: usage
      )
    end
end
