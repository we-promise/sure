require "test_helper"

class Provider::OpenaiTest < ActiveSupport::TestCase
  include LLMInterfaceTest

  setup do
    @subject = @openai = Provider::Openai.new(ENV.fetch("OPENAI_ACCESS_TOKEN", "test-openai-token"))
    @subject_model = "gpt-4.1"
  end

  %w[gpt-6-sol gpt-6.1-sol].each do |model|
    test "builtin assistant resolves #{model} to the native Responses provider" do
      with_env_overrides(
        "OPENAI_ACCESS_TOKEN" => "test-openai-token",
        "OPENAI_URI_BASE" => nil,
        "OPENAI_MODEL" => model,
        "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => nil
      ) do
        Setting.stubs(:openai_uri_base).returns(nil)
        assistant = Assistant::Builtin.for_chat(chats(:two))
        provider = assistant.get_model_provider(model)

        assert_instance_of Provider::Openai, provider
        assert provider.supports_responses_endpoint?
      end
    end
  end

  test "GPT-6.1 Sol sends assistant tools through Responses with supported request parameters" do
    with_env_overrides("OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => nil) do
      fake_responses = mock
      fake_client = mock
      fake_client.stubs(:responses).returns(fake_responses)
      fake_client.expects(:chat).never
      @openai.stubs(:client).returns(fake_client)

      fake_responses.expects(:create).with do |parameters:|
        parameters[:model] == "gpt-6.1-sol" &&
          parameters[:tools].first[:name] == "get_net_worth" &&
          !parameters.key?(:reasoning) && !parameters.key?(:reasoning_effort)
      end.returns(
        "id" => "resp_sol61", "model" => "gpt-6.1-sol",
        "output" => [ {
          "type" => "function_call", "id" => "fc_sol61", "call_id" => "call_sol61",
          "name" => "get_net_worth", "arguments" => "{}"
        } ]
      )

      response = @openai.chat_response(
        "What is my net worth?", model: "gpt-6.1-sol",
        functions: [ { name: "get_net_worth", params_schema: { type: "object", properties: {} } } ]
      )

      assert response.success?
      assert_equal "get_net_worth", response.data.function_requests.first.function_name
    end
  end

  # The registry and the settings form both stop a custom base URL without a
  # model before it gets here; this is the provider's own guard behind them.
  test "a custom base URL without a model is refused" do
    error = assert_raises(Provider::Openai::Error) do
      Provider::Openai.new("ollama-local", uri_base: "http://localhost:11434/v1", model: nil)
    end

    assert_match(/Model is required/, error.message)
  end

  test "a custom base URL accepts any model name, as a local server's models are its own" do
    local = Provider::Openai.new("ollama-local", uri_base: "http://localhost:11434/v1", model: "llama3.1")

    assert local.custom_provider?
    assert local.supports_model?("llama3.1")
    assert local.supports_model?("qwen2.5:32b")
  end

  test "effective_model uses Setting when ENV is unset" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => nil) do
      assert_equal "llama3", Provider::Openai.effective_model
    end
  end

  test "effective_model treats blank ENV as unset and uses Setting" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "") do
      assert_equal "llama3", Provider::Openai.effective_model
    end
  end

  test "effective_model prefers ENV over Setting" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_equal "gpt-4o", Provider::Openai.effective_model
    end
  end

  test "effective_model falls back to default when ENV and Setting are blank" do
    with_env_overrides("OPENAI_MODEL" => "") do
      Setting.stubs(:openai_model).returns(nil)
      assert_equal Provider::Openai::DEFAULT_MODEL, Provider::Openai.effective_model

      Setting.stubs(:openai_model).returns("")
      assert_equal Provider::Openai::DEFAULT_MODEL, Provider::Openai.effective_model
    end
  end

  test "request_timeout uses ENV then Setting then default" do
    Setting.stubs(:openai_request_timeout).returns(nil)
    with_env_overrides("OPENAI_REQUEST_TIMEOUT" => nil) do
      assert_equal Provider::Openai::DEFAULT_REQUEST_TIMEOUT, Provider::Openai.request_timeout
    end

    Setting.stubs(:openai_request_timeout).returns(180)
    with_env_overrides("OPENAI_REQUEST_TIMEOUT" => nil) do
      assert_equal 180, Provider::Openai.request_timeout
    end

    Setting.stubs(:openai_request_timeout).returns(180)
    with_env_overrides("OPENAI_REQUEST_TIMEOUT" => "300") do
      assert_equal 300, Provider::Openai.request_timeout
    end
  end

  test "request_timeout is passed to OpenAI client" do
    with_env_overrides("OPENAI_REQUEST_TIMEOUT" => nil, "OPENAI_EXTRA_HEADERS" => nil) do
      Setting.stubs(:openai_request_timeout).returns(180)
      ::OpenAI::Client.expects(:new).with(access_token: "test-token", request_timeout: 180).returns(mock)

      Provider::Openai.new("test-token")
    end
  end

  test "extra_headers parses valid JSON, stringifies keys and values, drops blanks" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-session": "abc", "Retry": 3, "empty": "", "drop": null}') do
      assert_equal({ "x-session" => "abc", "Retry" => "3" }, Provider::Openai.extra_headers)
    end
  end

  test "extra_headers stringifies nested values Ruby-style" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-meta":{"a":1}}') do
      assert_equal({ "x-meta" => '{"a" => 1}' }, Provider::Openai.extra_headers)
    end
  end

  test "extra_headers returns empty hash for unset, blank, malformed, and non-object JSON" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => nil) do
      assert_equal({}, Provider::Openai.extra_headers)
    end

    with_env_overrides("OPENAI_EXTRA_HEADERS" => "  ") do
      assert_equal({}, Provider::Openai.extra_headers)
    end

    with_env_overrides("OPENAI_EXTRA_HEADERS" => "{not json") do
      Rails.logger.expects(:error).with(regexp_matches(/OPENAI_EXTRA_HEADERS is not valid JSON/))
      assert_equal({}, Provider::Openai.extra_headers)
    end

    with_env_overrides("OPENAI_EXTRA_HEADERS" => "[1,2]") do
      Rails.logger.expects(:error).with(regexp_matches(/must be a JSON object/))
      assert_equal({}, Provider::Openai.extra_headers)
    end
  end

  test "client construction receives parsed extra_headers" do
    with_env_overrides(
      "OPENAI_REQUEST_TIMEOUT" => nil,
      "OPENAI_EXTRA_HEADERS" => '{"X-Static":"1"}'
    ) do
      Setting.stubs(:openai_request_timeout).returns(nil)
      ::OpenAI::Client.expects(:new).with(
        access_token: "test-token",
        request_timeout: 60,
        extra_headers: { "X-Static" => "1" }
      ).returns(mock)

      Provider::Openai.new("test-token")
    end
  end

  test "extra headers knob is documented in hosting docs and env examples" do
    doc = Rails.root.join("docs/hosting/ai.md").read
    assert_includes doc, "OPENAI_EXTRA_HEADERS"
    assert_includes doc, "{session_id}"

    assert_includes Rails.root.join(".env.example").read, "OPENAI_EXTRA_HEADERS"
    assert_includes Rails.root.join(".env.local.example").read, "OPENAI_EXTRA_HEADERS"
  end

  test "client construction receives static extra_headers only; session values withheld" do
    with_env_overrides(
      "OPENAI_REQUEST_TIMEOUT" => nil,
      "OPENAI_EXTRA_HEADERS" => '{"X-Static":"1","x-opencode-session":"sess-{session_id}"}'
    ) do
      Setting.stubs(:openai_request_timeout).returns(nil)
      ::OpenAI::Client.expects(:new).with(
        access_token: "test-token",
        request_timeout: 60,
        extra_headers: { "X-Static" => "1" }
      ).returns(mock)

      Provider::Openai.new("test-token")
    end
  end

  test "session headers substitute the chat id onto a request-scoped client copy" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-opencode-session":"sess-{session_id}","X-Static":"1"}') do
      subject = Provider::Openai.new("test-token")
      fake_client = mock
      scoped_client = mock
      fake_client.expects(:dup).returns(scoped_client)
      scoped_client.expects(:add_headers).with({ "x-opencode-session" => "sess-chat-42" })
      subject.stubs(:client).returns(fake_client)

      assert_same scoped_client, subject.send(:with_session_headers, session_id: "chat-42")
    end
  end

  test "session headers are absent from the request when no session_id is given" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-opencode-session":"sess-{session_id}"}') do
      subject = Provider::Openai.new("test-token")
      fake_client = mock
      fake_client.expects(:dup).never
      fake_client.expects(:add_headers).never
      subject.stubs(:client).returns(fake_client)

      assert_same subject.send(:client), subject.send(:with_session_headers, session_id: nil)
    end
  end

  test "session headers never persist onto the shared client after a chat request" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-opencode-session":"sess-{session_id}"}') do
      subject = Provider::Openai.new("test-token")
      scoped_client = mock
      fake_client = mock
      fake_client.expects(:dup).returns(scoped_client)
      scoped_client.expects(:add_headers).with({ "x-opencode-session" => "sess-chat-42" })
      fake_client.expects(:responses).never
      subject.stubs(:client).returns(fake_client)

      scoped = subject.send(:with_session_headers, session_id: "chat-42")

      assert_same scoped_client, scoped
      assert_same fake_client, subject.send(:client)
    end
  end

  test "native chat path resolves session headers onto a request-scoped client" do
    with_env_overrides("OPENAI_EXTRA_HEADERS" => '{"x-opencode-session":"sess-{session_id}"}') do
      subject = Provider::Openai.new("test-token")
      fake_responses = mock
      scoped_client = mock
      scoped_client.stubs(:responses).returns(fake_responses)
      fake_client = mock
      fake_client.stubs(:dup).returns(scoped_client)
      scoped_client.expects(:add_headers).with({ "x-opencode-session" => "sess-chat-42" })
      fake_responses.stubs(:create).returns(
        { "id" => "resp_1", "model" => "gpt-4.1", "output" => [], "usage" => { "total_tokens" => 1 } }
      )
      subject.stubs(:client).returns(fake_client)

      response = subject.chat_response("hi", model: "gpt-4.1", session_id: "chat-42")

      assert response.success?
    end
  end

  test "generic chat path resolves session headers onto a request-scoped client" do
    with_env_overrides(
      "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => "false",
      "OPENAI_EXTRA_HEADERS" => '{"x-opencode-session":"sess-{session_id}"}'
    ) do
      subject = Provider::Openai.new("test-token")
      scoped_client = mock
      fake_client = mock
      fake_client.stubs(:dup).returns(scoped_client)
      scoped_client.expects(:add_headers).with({ "x-opencode-session" => "sess-chat-42" })
      scoped_client.stubs(:chat).returns(
        { "id" => "resp_1", "model" => "gpt-4.1", "choices" => [ { "message" => { "content" => "Yes" } } ],
          "usage" => { "total_tokens" => 1 } }
      )
      subject.stubs(:client).returns(fake_client)

      response = subject.chat_response("hi", model: "gpt-4.1", session_id: "chat-42")

      assert response.success?
      assert_equal "Yes", response.data.messages.first.output_text
    end
  end

  test "openai errors are automatically raised" do
    VCR.use_cassette("openai/chat/error") do
      response = @openai.chat_response("Test", model: "invalid-model-that-will-trigger-api-error")

      assert_not response.success?
      assert_kind_of Provider::Openai::Error, response.error
    end
  end

  test "basic chat response" do
    VCR.use_cassette("openai/chat/basic_response") do
      response = @subject.chat_response(
        "This is a chat test.  If it's working, respond with a single word: Yes",
        model: @subject_model
      )

      assert response.success?
      assert_equal 1, response.data.messages.size
      assert_includes response.data.messages.first.output_text, "Yes"
    end
  end

  test "streams basic chat response" do
    VCR.use_cassette("openai/chat/basic_streaming_response") do
      collected_chunks = []

      mock_streamer = proc do |chunk|
        collected_chunks << chunk
      end

      response = @subject.chat_response(
        "This is a chat test.  If it's working, respond with a single word: Yes",
        model: @subject_model,
        streamer: mock_streamer
      )

      text_chunks = collected_chunks.select { |chunk| chunk.type == "output_text" }
      response_chunks = collected_chunks.select { |chunk| chunk.type == "response" }

      assert_equal 1, text_chunks.size
      assert_equal 1, response_chunks.size
      assert_equal "Yes", text_chunks.first.data
      assert_equal "Yes", response_chunks.first.data.messages.first.output_text
      assert_equal response_chunks.first.data, response.data
    end
  end

  test "chat response with function calls" do
    VCR.use_cassette("openai/chat/function_calls") do
      prompt = "What is my net worth?"

      functions = [
        {
          name: "get_net_worth",
          description: "Gets a user's net worth",
          params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
          strict: true
        }
      ]

      first_response = @subject.chat_response(
        prompt,
        model: @subject_model,
        instructions: "Use the tools available to you to answer the user's question.",
        functions: functions
      )

      assert first_response.success?

      function_request = first_response.data.function_requests.first

      assert function_request.present?

      second_response = @subject.chat_response(
        prompt,
        model: @subject_model,
        function_results: [ {
          call_id: function_request.call_id,
          output: { amount: 10000, currency: "USD" }.to_json
        } ],
        previous_response_id: first_response.data.id
      )

      assert second_response.success?
      assert_equal 1, second_response.data.messages.size
      assert_includes second_response.data.messages.first.output_text, "$10,000"
    end
  end

  test "streams chat response with function calls" do
    VCR.use_cassette("openai/chat/streaming_function_calls") do
      collected_chunks = []

      mock_streamer = proc do |chunk|
        collected_chunks << chunk
      end

      prompt = "What is my net worth?"

      functions = [
        {
          name: "get_net_worth",
          description: "Gets a user's net worth",
          params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
          strict: true
        }
      ]

      # Call #1: First streaming call, will return a function request
      @subject.chat_response(
        prompt,
        model: @subject_model,
        instructions: "Use the tools available to you to answer the user's question.",
        functions: functions,
        streamer: mock_streamer
      )

      text_chunks = collected_chunks.select { |chunk| chunk.type == "output_text" }
      response_chunks = collected_chunks.select { |chunk| chunk.type == "response" }

      assert_equal 0, text_chunks.size
      assert_equal 1, response_chunks.size

      first_response = response_chunks.first.data
      function_request = first_response.function_requests.first

      # Reset collected chunks for the second call
      collected_chunks = []

      # Call #2: Second streaming call, will return a function result
      @subject.chat_response(
        prompt,
        model: @subject_model,
        function_results: [
          {
            call_id: function_request.call_id,
            output: { amount: 10000, currency: "USD" }
          }
        ],
        previous_response_id: first_response.id,
        streamer: mock_streamer
      )

      text_chunks = collected_chunks.select { |chunk| chunk.type == "output_text" }
      response_chunks = collected_chunks.select { |chunk| chunk.type == "response" }

      assert text_chunks.size >= 1
      assert_equal 1, response_chunks.size

      assert_includes response_chunks.first.data.messages.first.output_text, "$10,000"
    end
  end

  test "provider_name returns OpenAI for standard provider" do
    assert_equal "OpenAI", @subject.provider_name
  end

  test "provider_name returns custom info for custom provider" do
    custom_provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://custom-api.example.com/v1",
      model: "custom-model"
    )

    assert_equal "Custom OpenAI-compatible (https://custom-api.example.com/v1)", custom_provider.provider_name
  end

  test "supported_models_description returns model prefixes for standard provider" do
    expected = "models starting with: gpt-4, gpt-5, gpt-6, o1, o3"
    assert_equal expected, @subject.supported_models_description
  end

  test "supported_models_description returns configured model for custom provider" do
    custom_provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://custom-api.example.com/v1",
      model: "custom-model"
    )

    assert_equal "configured model: custom-model", custom_provider.supported_models_description
  end

  test "finishes the root observation with output and error level" do
    trace = mock
    trace.expects(:end).with(output: { ok: true }, level: "ERROR")
    @subject.send(:finish_langfuse_trace, trace: trace, output: { ok: true }, level: "ERROR")
  end

  test "configured tracing emits chat observations through the shared OpenTelemetry client" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    tracing = LangfuseTracing.new(public_key: "pk-test", secret_key: "sk-test", host: "https://langfuse.test",
      processor: OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    Rails.configuration.x.stubs(:langfuse).returns(tracing)
    with_env_overrides("LANGFUSE_PUBLIC_KEY" => "pk-test", "LANGFUSE_SECRET_KEY" => "sk-test") do
      @subject.send(:log_langfuse_generation, name: "chat_response", model: "gpt-4.1", input: "Hi", output: "Hello",
        usage: { "prompt_tokens" => 4, "completion_tokens" => 2 }, session_id: "chat-id", user_identifier: "hashed-id")
    end
    assert_equal 2, exporter.finished_spans.size
    exporter.finished_spans.each do |span|
      assert_equal "chat-id", span.attributes["langfuse.session.id"]
      assert_equal "hashed-id", span.attributes["langfuse.user.id"]
    end
  ensure
    tracing&.shutdown
  end

  test "log_langfuse_generation finishes generation and root observation" do
    trace = Struct.new(:id).new("trace_456")
    generation = mock
    fake_client = mock

    @subject.stubs(:langfuse_client).returns(fake_client)
    @subject.stubs(:create_langfuse_trace).returns(trace)

    trace.expects(:end).with(output: "hello", level: nil)
    trace.expects(:generation).returns(generation)
    generation.expects(:end).with(output: "hello", usage: { "total_tokens" => 10 })

    @subject.send(
      :log_langfuse_generation,
      name: "chat",
      model: "gpt-4.1",
      input: { prompt: "Hi" },
      output: "hello",
      usage: { "total_tokens" => 10 }
    )
  end

  test "create_langfuse_trace logs the error without its backtrace" do
    fake_client = mock
    error = StandardError.new("boom")

    @subject.stubs(:langfuse_client).returns(fake_client)
    fake_client.expects(:trace).raises(error)

    Rails.logger.expects(:warn).with("Langfuse trace creation failed: StandardError: boom")

    @subject.send(:create_langfuse_trace, name: "openai.test", input: { foo: "bar" })
  end

  test "SUPPORTED_MODELS and VISION_CAPABLE_MODEL_PREFIXES are Ruby constants, not YAML-derived" do
    assert_kind_of Array, Provider::Openai::SUPPORTED_MODELS
    assert Provider::Openai::SUPPORTED_MODELS.all? { |s| s.is_a?(String) }
    assert Provider::Openai::SUPPORTED_MODELS.frozen?

    assert_kind_of Array, Provider::Openai::VISION_CAPABLE_MODEL_PREFIXES
    assert Provider::Openai::VISION_CAPABLE_MODEL_PREFIXES.frozen?
    assert_equal "gpt-4.1", Provider::Openai::DEFAULT_MODEL
  end

  test "budget readers default to conservative values" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_SYSTEM_PROMPT_RESERVE" => nil,
      "LLM_MAX_HISTORY_TOKENS" => nil,
      "LLM_MAX_ITEMS_PER_CALL" => nil
    ) do
      subject = Provider::Openai.new("test-token")
      assert_equal 2048, subject.context_window
      assert_equal 512, subject.max_response_tokens
      assert_equal 256, subject.system_prompt_reserve
      assert_equal 2048 - 512 - 256, subject.max_history_tokens
    end
  end

  test "budget readers respect explicit env overrides" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => "8192",
      "LLM_MAX_RESPONSE_TOKENS" => "1024",
      "LLM_SYSTEM_PROMPT_RESERVE" => "512",
      "LLM_MAX_HISTORY_TOKENS" => "4096",
      "LLM_MAX_ITEMS_PER_CALL" => "50"
    ) do
      subject = Provider::Openai.new("test-token")
      assert_equal 8192, subject.context_window
      assert_equal 1024, subject.max_response_tokens
      assert_equal 512, subject.system_prompt_reserve
      assert_equal 4096, subject.max_history_tokens  # explicit overrides derived
    end
  end

  test "history budget subtracts the real instructions estimate when given" do
    Setting.stubs(:llm_max_response_tokens).returns(nil)

    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => "8192",
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_SYSTEM_PROMPT_RESERVE" => nil,
      "LLM_MAX_HISTORY_TOKENS" => nil
    ) do
      subject = Provider::Openai.new("test-token")
      instructions = "a" * 4000
      estimate = Assistant::TokenEstimator.estimate(instructions)

      assert_equal 8192 - 512 - estimate, subject.max_history_tokens(instructions: instructions)
      # Without instructions the flat reserve still applies
      assert_equal 8192 - 512 - 256, subject.max_history_tokens
    end
  end

  test "response cap is only sent when explicitly configured" do
    with_env_overrides("LLM_MAX_RESPONSE_TOKENS" => nil) do
      Setting.stubs(:llm_max_response_tokens).returns(nil)
      subject = Provider::Openai.new("test-token")

      assert_nil subject.explicit_max_response_tokens
    end

    with_env_overrides("LLM_MAX_RESPONSE_TOKENS" => nil) do
      Setting.stubs(:llm_max_response_tokens).returns(768)
      subject = Provider::Openai.new("test-token")

      assert_equal 768, subject.explicit_max_response_tokens
    end

    with_env_overrides("LLM_MAX_RESPONSE_TOKENS" => "900") do
      subject = Provider::Openai.new("test-token")

      assert_equal 900, subject.explicit_max_response_tokens
    end
  end

  test "budget readers fall back to Setting when ENV unset" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => nil,
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_MAX_ITEMS_PER_CALL" => nil
    ) do
      Setting.llm_context_window = 8192
      Setting.llm_max_response_tokens = 1024
      Setting.llm_max_items_per_call = 40

      subject = Provider::Openai.new("test-token")
      assert_equal 8192, subject.context_window
      assert_equal 1024, subject.max_response_tokens
    end
  ensure
    Setting.llm_context_window = nil
    Setting.llm_max_response_tokens = nil
    Setting.llm_max_items_per_call = nil
  end

  test "budget readers: ENV beats Setting when both present" do
    with_env_overrides("LLM_CONTEXT_WINDOW" => "16384") do
      Setting.llm_context_window = 4096
      subject = Provider::Openai.new("test-token")
      assert_equal 16384, subject.context_window
    end
  ensure
    Setting.llm_context_window = nil
  end

  test "budget readers: zero or negative values fall through to default" do
    with_env_overrides(
      "LLM_CONTEXT_WINDOW" => "0",
      "LLM_MAX_RESPONSE_TOKENS" => nil,
      "LLM_MAX_ITEMS_PER_CALL" => nil
    ) do
      Setting.llm_context_window = 0
      subject = Provider::Openai.new("test-token")
      assert_equal 2048, subject.context_window
    end
  ensure
    Setting.llm_context_window = nil
  end

  test "streaming surfaces a useful error when the stream ends with response.failed and no completion" do
    fake_responses = mock
    fake_client = mock
    fake_client.stubs(:responses).returns(fake_responses)
    @subject.stubs(:client).returns(fake_client)

    fake_responses.expects(:create).with do |*_args, **kwargs|
      stream = kwargs.dig(:parameters, :stream)
      stream.call({
        "type" => "response.failed",
        "response" => {
          "error" => { "message" => "Previous response not found", "code" => "previous_response_not_found" }
        }
      })
      true
    end.returns(nil)

    response = @subject.chat_response(
      "hi",
      model: @subject_model,
      streamer: proc { |_| }
    )

    assert_not response.success?
    assert_kind_of Provider::Openai::Error, response.error
    assert_match(/Previous response not found/, response.error.message)
    assert_match(/previous_response_not_found/, response.error.message)
  end

  test "streaming surfaces a useful error when the stream ends with no response and no error event" do
    fake_responses = mock
    fake_client = mock
    fake_client.stubs(:responses).returns(fake_responses)
    @subject.stubs(:client).returns(fake_client)

    fake_responses.expects(:create).returns(nil)

    response = @subject.chat_response(
      "hi",
      model: @subject_model,
      streamer: proc { |_| }
    )

    assert_not response.success?
    assert_kind_of Provider::Openai::Error, response.error
    assert_match(/stream ended without a completion event/i, response.error.message)
  end

  test "build_input no longer accepts inline messages history" do
    config = Provider::Openai::ChatConfig.new(functions: [], function_results: [])
    # Positive control: prompt works
    result = config.build_input(prompt: "hi")
    assert_equal [ { role: "user", content: "hi" } ], result

    # `messages:` kwarg is no longer part of the signature — calling with it must raise
    assert_raises(ArgumentError) do
      config.build_input(prompt: "hi", messages: [ { role: "user", content: "old" } ])
    end
  end

  test "generic chat path omits tool message name and sends string arguments" do
    provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://example.com/v1",
      model: "test-model"
    )

    client = provider.instance_variable_get(:@client)
    captured_params = nil
    client.expects(:chat).with do |params|
      captured_params = params.fetch(:parameters)
      true
    end.returns(
      {
        "id" => "chatcmpl-1",
        "model" => "test-model",
        "choices" => [ { "message" => { "role" => "assistant", "content" => "ok" } } ],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 }
      }
    )

    response = provider.chat_response(
      "What is my net worth?",
      model: "test-model",
      functions: [ {
        name: "get_net_worth",
        description: "Gets a user's net worth",
        params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
        strict: true
      } ],
      function_results: [ {
        call_id: "call_1",
        name: "get_net_worth",
        arguments: { "currency" => "USD" },
        output: { "amount" => 10000 }
      } ]
    )

    assert response.success?

    tool_calls = captured_params[:messages]
                       .select { |m| m[:role] == "assistant" }
                       .flat_map { |m| m[:tool_calls] || [] }
    assert_equal 1, tool_calls.size
    assert_equal "get_net_worth", tool_calls.first.dig(:function, :name)
    assert_instance_of String, tool_calls.first.dig(:function, :arguments)
    assert_equal({ "currency" => "USD" }, JSON.parse(tool_calls.first.dig(:function, :arguments)))

    tool_messages = captured_params[:messages].select { |m| m[:role] == "tool" }
    assert_equal 1, tool_messages.size
    assert_equal "call_1", tool_messages.first[:tool_call_id]
    assert_not tool_messages.first.key?(:name), "tool messages must not carry the deprecated `name` field"
  end

  test "generic chat builder normalizes blank arguments to an empty JSON object" do
    provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://example.com/v1",
      model: "test-model"
    )

    messages = provider.send(
      :build_generic_messages,
      prompt: "hi",
      function_results: [ { call_id: "call_1", name: "get_net_worth", arguments: "", output: { "amount" => 10000 } } ]
    )

    tool_call = messages.find { |m| m[:role] == "assistant" }[:tool_calls].first
    assert_equal "{}", tool_call.dig(:function, :arguments)
  end

  test "build_generic_messages preserves extra_content on assistant tool_calls when present" do
    provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://generativelanguage.googleapis.com/v1beta/openai",
      model: "gemini-3.8-flash"
    )

    extra = { "google" => { "thought_signature" => "sig_encrypted_token_123" } }
    messages = provider.send(
      :build_generic_messages,
      prompt: "hi",
      function_results: [
        {
          call_id: "call_1",
          name: "get_net_worth",
          arguments: "{}",
          output: { "amount" => 10000 },
          extra_content: extra
        }
      ]
    )

    assistant_message = messages.find { |m| m[:role] == "assistant" }
    tool_call = assistant_message[:tool_calls].first
    assert_equal extra, tool_call[:extra_content]
  end

  test "build_generic_messages omits extra_content on assistant tool_calls when nil" do
    provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://example.com/v1",
      model: "test-model"
    )

    messages = provider.send(
      :build_generic_messages,
      prompt: "hi",
      function_results: [
        {
          call_id: "call_1",
          name: "get_net_worth",
          arguments: "{}",
          output: { "amount" => 10000 },
          extra_content: nil
        }
      ]
    )

    assistant_message = messages.find { |m| m[:role] == "assistant" }
    tool_call = assistant_message[:tool_calls].first
    assert_not_includes tool_call.keys, :extra_content
  end

  test "build_generic_messages replays each tool round as its own assistant/tool pair" do
    provider = Provider::Openai.new(
      "test-token",
      uri_base: "https://example.com/v1",
      model: "test-model"
    )

    extra = { "google" => { "thought_signature" => "sig_round_2" } }
    round_1 = [
      { call_id: "call_a", name: "get_accounts", arguments: "{}", output: { "accounts" => [] }, round: 1 }
    ]
    round_2 = [
      { call_id: "call_b", name: "get_categories", arguments: "{}", output: { "categories" => [] }, round: 2 },
      { call_id: "call_c", name: "get_tags", arguments: "{}", output: { "tags" => [] }, extra_content: extra, round: 2 }
    ]

    build = ->(function_results) do
      provider.send(:build_generic_messages, prompt: "hi", instructions: "system", function_results: function_results)
    end
    second_request = build.call(round_1)
    third_request = build.call(round_1 + round_2)

    # Each follow-up request must extend the previous one so prefix caches stay valid.
    assert_equal second_request, third_request.first(second_request.size)

    shape = third_request.map do |message|
      message[:tool_calls] ? message[:tool_calls].map { |call| call[:id] } : message[:tool_call_id] || message[:role]
    end
    assert_equal [ "system", "user", [ "call_a" ], "call_a", [ "call_b", "call_c" ], "call_b", "call_c" ], shape

    round_2_calls = third_request[4][:tool_calls]
    assert_not round_2_calls.first.key?(:extra_content)
    assert_equal extra, round_2_calls.last[:extra_content]
    assert_not_includes third_request.to_json, "\"round\":", "the round tag must not leak into the request"
  end

  test "OpenRouter chat records provider cost and tokens for an unknown model with a streamer" do
    provider = Provider::Openai.new("test-token", uri_base: "https://openrouter.ai/api/v1", model: "deepseek/example-model")
    usage = { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15, "cost" => 0.012345 }
    provider.send(:client).expects(:chat).returns(
      "id" => "chatcmpl-synthetic", "choices" => [ { "message" => { "role" => "assistant", "content" => "Hello" } } ],
      "usage" => usage
    )
    chunks = []
    family = families(:dylan_family)

    assert_difference -> { family.llm_usages.count }, 1 do
      response = provider.chat_response("Hello", model: "deepseek/example-model", family: family, streamer: ->(chunk) { chunks << chunk })
      assert response.success?
    end

    recorded = family.llm_usages.order(:created_at).last
    assert_equal BigDecimal("0.012345"), recorded.estimated_cost
    assert_equal [ 10, 5, 15 ], [ recorded.prompt_tokens, recorded.completion_tokens, recorded.total_tokens ]
    assert_equal usage, chunks.last.usage
  end

  test "OpenRouter chat falls back to token estimates when reported cost is absent or invalid" do
    provider = Provider::Openai.new("test-token", uri_base: "https://openrouter.ai/api/v1", model: "gpt-4.1")
    family = families(:dylan_family)
    expected = LlmUsage.calculate_cost(model: "gpt-4.1", prompt_tokens: 1000, completion_tokens: 100)

    [ {}, { "cost" => -1 }, { "cost" => "NaN" }, { "cost" => "not a cost" } ].each do |extra_usage|
      usage = { "prompt_tokens" => 1000, "completion_tokens" => 100, "total_tokens" => 1100 }.merge(extra_usage)
      provider.send(:client).expects(:chat).returns(
        "id" => "chatcmpl-synthetic", "choices" => [ { "message" => { "role" => "assistant", "content" => "Hello" } } ],
        "usage" => usage
      )

      assert_difference -> { family.llm_usages.count }, 1 do
        assert provider.chat_response("Hello", model: "gpt-4.1", family: family).success?
      end

      recorded = family.llm_usages.order(:created_at).last
      assert_equal expected, recorded.estimated_cost
      assert_equal [ 1000, 100, 1100 ], [ recorded.prompt_tokens, recorded.completion_tokens, recorded.total_tokens ]
    end
  end

  test "OpenRouter Responses stream forwards reported zero cost to the ledger" do
    provider = Provider::Openai.new("test-token", uri_base: "https://openrouter.ai/api/v1", model: "deepseek/example-model")
    provider.stubs(:supports_responses_endpoint?).returns(true)
    usage = { "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15, "cost" => 0 }
    provider.send(:client).responses.expects(:create).with do |parameters:|
      parameters[:stream].call({
        "type" => "response.completed",
        "response" => { "id" => "resp-synthetic", "model" => "deepseek/example-model", "output" => [], "usage" => usage }
      })
      true
    end.returns(nil)
    family = families(:dylan_family)

    assert_difference -> { family.llm_usages.count }, 1 do
      response = provider.chat_response("Hello", model: "deepseek/example-model", family: family, streamer: ->(_) { })
      assert response.success?
    end

    recorded = family.llm_usages.order(:created_at).last
    assert_equal BigDecimal("0"), recorded.estimated_cost
    assert_equal [ 10, 5, 15 ], [ recorded.prompt_tokens, recorded.completion_tokens, recorded.total_tokens ]
  end


  test "the client takes its proxy from Ai::Transport::Http, never proxying loopback" do
    ClimateControl.modify(HTTPS_PROXY: "http://proxy.internal:8888", HTTP_PROXY: nil, NO_PROXY: nil, no_proxy: nil) do
      cloud = Faraday.new.tap { Provider::Openai.new("token").send(:client).faraday_middleware.call(_1) }
      local = Faraday.new.tap { Provider::Openai.new("token", uri_base: "http://127.0.0.1:8080/v1", model: "qwen3").send(:client).faraday_middleware.call(_1) }

      assert_equal URI("http://proxy.internal:8888"), cloud.proxy.uri
      assert_nil local.proxy
    end
  end
end
