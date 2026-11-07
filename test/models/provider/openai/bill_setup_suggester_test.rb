require "test_helper"

class Provider::Openai::BillSetupSuggesterTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @charges = [
      { date: Date.new(2025, 1, 15), amount: 9.99, name: "STREAMING SVC" },
      { date: Date.new(2025, 2, 15), amount: 9.99, name: "STREAMING SVC" }
    ]
  end

  test "sends reasoning_effort when configured" do
    captured = nil
    @client.expects(:chat).once
      .with { |args| captured = args[:parameters]; true }
      .returns(chat_response)

    Setting.stubs(:openai_reasoning_effort).returns("low")
    with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
      suggester.suggest
    end

    assert_equal "low", captured[:reasoning_effort]
  end

  test "400 retry drops both response_format and reasoning_effort" do
    captured = []
    @client.expects(:chat).twice
      .with { |args| captured << args[:parameters]; true }
      .raises(Faraday::BadRequestError, "bad request")
      .then
      .returns(chat_response)

    Setting.stubs(:openai_reasoning_effort).returns("low")
    with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
      suggester.suggest
    end

    assert_equal({ type: "json_object" }, captured.first[:response_format])
    assert_equal "low", captured.first[:reasoning_effort]

    assert_not captured.second.key?(:response_format)
    assert_not captured.second.key?(:reasoning_effort)
  end

  private
    def suggester
      Provider::Openai::BillSetupSuggester.new(
        @client,
        model: "test-model",
        charges: @charges,
        categories: [ "Subscriptions" ]
      )
    end

    def chat_response
      {
        "choices" => [ { "message" => { "content" => '{"name":"Streaming","amount":9.99,"frequency":"monthly","confidence":0.9}' } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end
end
