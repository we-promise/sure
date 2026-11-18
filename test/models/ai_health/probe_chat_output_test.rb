require "test_helper"

class AiHealth::ProbeChatOutputTest < ActiveSupport::TestCase
  PROTOCOLS = %i[chat_completions responses anthropic].freeze

  setup do
    @probe = AiHealth::Probe.new(cache: ActiveSupport::Cache::MemoryStore.new)
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)
  end

  PROTOCOLS.each do |protocol|
    { ok: "OK", nonliteral: "All systems working", empty: "", nil: nil, whitespace: "   \n  " }.each do |scenario, content|
      test "#{protocol}: chat probe checks #{scenario} output" do
        endpoint = configured_endpoint(protocol)
        request = stub_chat_response(protocol, content)

        result = @probe.llm(provider: protocol == :anthropic ? :anthropic : :openai,
                            endpoint: endpoint.base_url, access_token: "test-token", model: "test-model")

        assert_requested request
        if %i[ok nonliteral].include?(scenario)
          assert result.passing?
        else
          assert result.failing?
          assert_equal :invalid_response, result.failure_code
        end
      end
    end

    test "#{protocol}: chat probe preserves nonblank answer text" do
      endpoint = configured_endpoint(protocol)
      text = "  All systems working\n"
      stub_chat_response(protocol, text)

      assert_equal text, Ai::Transport.for(endpoint).probe(ai_model(endpoint:), :chat)
    end

    test "#{protocol}: model-list probe does not send a chat request" do
      endpoint = configured_endpoint(protocol, probe_check: :models)
      url = protocol == :anthropic ? "#{endpoint.base_url}/v1/models/test-model" : "#{endpoint.base_url}/models"
      body = protocol == :anthropic ? { id: "test-model" } : { data: [ { id: "test-model" } ] }
      request = stub_request(:get, url).to_return(status: 200, headers: json_headers, body: body.to_json)

      result = @probe.llm(provider: protocol == :anthropic ? :anthropic : :openai,
                          endpoint: endpoint.base_url, access_token: "test-token", model: "test-model")

      assert result.passing?
      assert_requested request
      assert_not_requested :post, chat_url(protocol)
    end
  end

  private
    def configured_endpoint(protocol, probe_check: :chat)
      endpoint = ai_endpoint(protocol: protocol == :anthropic ? :anthropic : :compatible,
                              base_url: protocol == :anthropic ? "https://anthropic.example.test" : "https://llm.example.test/v1",
                              responses_api: protocol == :responses, probe_check:)
      @probe.stubs(:configured_endpoint).returns(endpoint)
      endpoint
    end

    def chat_url(protocol)
      case protocol
      when :chat_completions then "https://llm.example.test/v1/chat/completions"
      when :responses then "https://llm.example.test/v1/responses"
      when :anthropic then "https://anthropic.example.test/v1/messages"
      end
    end

    def json_headers = { "Content-Type" => "application/json" }

    def stub_chat_response(protocol, content)
      body = { model: "test-model" }
      case protocol
      when :chat_completions
        body.merge!(id: "c1", choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: } } ])
      when :responses
        output = content.nil? ? [] : [ { type: "message", id: "msg_1", role: "assistant", status: "completed",
                                         content: [ { type: "output_text", text: content, annotations: [] } ] } ]
        body.merge!(id: "r1", status: "completed", output:)
      when :anthropic
        body.merge!(id: "m1", type: "message", role: "assistant", stop_reason: "end_turn",
                    content: content.nil? ? [] : [ { type: "text", text: content } ],
                    usage: { input_tokens: 20, output_tokens: 10 })
      end

      stub_request(:post, chat_url(protocol)).to_return(status: 200, headers: json_headers, body: body.to_json)
    end
end
