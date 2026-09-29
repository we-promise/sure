require "test_helper"

class Provider::Openai::AutoCategorizerReasoningTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @transactions = [
      { id: "1", name: "McDonalds", amount: 20, classification: "expense" }
    ]
    @user_categories = [
      { id: "cat1", name: "Food", is_subcategory: false, parent_id: nil, classification: "expense" }
    ]
  end

  test "generic request omits reasoning_effort when unset" do
    captured = nil
    @client.expects(:chat).once
      .with { |args| captured = args[:parameters]; true }
      .returns(chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}'))

    Setting.stubs(:openai_reasoning_effort).returns(nil)
    with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
      categorizer(json_mode: "none").auto_categorize
    end

    assert_not captured.key?(:reasoning_effort)
  end

  test "generic request sends reasoning_effort when configured via Setting" do
    captured = nil
    @client.expects(:chat).once
      .with { |args| captured = args[:parameters]; true }
      .returns(chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}'))

    Setting.stubs(:openai_reasoning_effort).returns("none")
    with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
      categorizer(json_mode: "none").auto_categorize
    end

    assert_equal "none", captured[:reasoning_effort]
  end

  private

    def categorizer(json_mode:)
      Provider::Openai::AutoCategorizer.new(
        @client,
        model: "test-model",
        transactions: @transactions,
        user_categories: @user_categories,
        custom_provider: true,
        json_mode: json_mode
      )
    end

    def chat_response(content)
      {
        "choices" => [ { "message" => { "content" => content } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end
end
