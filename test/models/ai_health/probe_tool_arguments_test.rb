require "test_helper"

class AiHealth::ProbeToolArgumentsTest < ActiveSupport::TestCase
  PROTOCOLS = %i[chat_completions responses anthropic].freeze

  setup do
    @probe = AiHealth::Probe.new(run: true)
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)
  end

  PROTOCOLS.each do |protocol|
    {
      valid: [ [ "sure_health_check", { status: "ok" } ] ],
      missing_status: [ [ "sure_health_check", {} ] ],
      wrong_status: [ [ "sure_health_check", { status: "bad" } ] ],
      null_status: [ [ "sure_health_check", { status: nil } ] ],
      extra_argument: [ [ "sure_health_check", { status: "ok", unexpected: true } ] ],
      non_object: [ [ "sure_health_check", [ "ok" ] ] ],
      wrong_name: [ [ "another_tool", { status: "ok" } ] ],
      multiple_invalid: [ [ "sure_health_check", {} ], [ "another_tool", { status: "ok" } ] ],
      one_valid: [ [ "sure_health_check", {} ], [ "sure_health_check", { status: "ok" } ] ]
    }.each do |scenario, calls|
      test "#{protocol}: tool probe validates #{scenario} arguments" do
        request = stub_tool_response(protocol, calls)

        result = probe_tools(protocol)

        assert_requested request
        if %i[valid one_valid].include?(scenario)
          assert result.passing?
        else
          assert result.failing?
          assert_equal :no_tool_call, result.failure_code
        end
      end
    end
  end

  %i[chat_completions responses].each do |protocol|
    test "#{protocol}: malformed tool arguments fail the probe" do
      request = stub_tool_response(protocol, [ [ "sure_health_check", '{"status":' ] ], serialized: true)

      result = probe_tools(protocol)

      assert_requested request
      assert result.failing?
    end
  end

  private
    def probe_tools(protocol)
      @probe.function_calling(
        provider: protocol == :anthropic ? :anthropic : :openai,
        endpoint: protocol == :anthropic ? "https://api.anthropic.com" : "https://llm.example.test/v1",
        access_token: "test-token", model: "test-model", use_responses_endpoint: protocol == :responses
      )
    end

    def stub_tool_response(protocol, calls, serialized: false)
      body = { model: "test-model" }
      case protocol
      when :chat_completions
        url = "https://llm.example.test/v1/chat/completions"
        tool_calls = calls.each_with_index.map do |(name, arguments), index|
          { id: "call_#{index}", type: "function", function: { name:, arguments: serialized ? arguments : arguments.to_json } }
        end
        body.merge!(id: "c1", choices: [ { index: 0, finish_reason: "tool_calls", message: { role: "assistant", tool_calls: } } ])
      when :responses
        url = "https://llm.example.test/v1/responses"
        output = calls.each_with_index.map do |(name, arguments), index|
          { type: "function_call", id: "fc_#{index}", call_id: "call_#{index}", name:, arguments: serialized ? arguments : arguments.to_json }
        end
        body.merge!(id: "r1", status: "completed", output:)
      when :anthropic
        url = "https://api.anthropic.com/v1/messages"
        content = calls.each_with_index.map do |(name, arguments), index|
          { type: "tool_use", id: "toolu_#{index}", name:, input: arguments }
        end
        body.merge!(id: "m1", type: "message", role: "assistant", stop_reason: "tool_use", content:,
                    usage: { input_tokens: 20, output_tokens: 10 })
      end

      stub_request(:post, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
    end
end
