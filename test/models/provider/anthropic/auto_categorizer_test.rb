require "test_helper"

class Provider::Anthropic::AutoCategorizerTest < ActiveSupport::TestCase
  setup do
    @transactions = [
      { id: "txn_1", name: "McDonalds", amount: 20, classification: "expense" },
      { id: "txn_2", name: "Netflix", amount: 15, classification: "expense" }
    ]
    @user_categories = [
      { id: "cat_food", name: "Fast Food", classification: "expense" },
      { id: "cat_subs", name: "Subscriptions", classification: "expense" }
    ]
  end

  test "issues a forced tool call and maps the response into AutoCategorization records" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_categorizations",
        input: {
          "categorizations" => [
            { "transaction_id" => "txn_1", "category_name" => "Fast Food" },
            { "transaction_id" => "txn_2", "category_name" => "Subscriptions" }
          ]
        }
      )
    ])
    client = stub_client(fake_response, expect_request: ->(params) {
      assert_equal "claude-haiku-4-5", params[:model]
      assert_equal [ { type: "tool", name: "report_categorizations", disable_parallel_tool_use: true } ].first, params[:tool_choice]
      assert_equal 1, params[:tools].size
      assert_equal "report_categorizations", params[:tools].first[:name]
    })

    result = Provider::Anthropic::AutoCategorizer.new(
      client,
      model: "claude-haiku-4-5",
      transactions: @transactions,
      user_categories: @user_categories
    ).auto_categorize

    assert_equal 2, result.size
    assert_equal "Fast Food", result.find { |r| r.transaction_id == "txn_1" }.category_name
    assert_equal "Subscriptions", result.find { |r| r.transaction_id == "txn_2" }.category_name
  end

  test "normalizes null category names to nil" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_2",
        name: "report_categorizations",
        input: {
          "categorizations" => [
            { "transaction_id" => "txn_1", "category_name" => nil },
            { "transaction_id" => "txn_2", "category_name" => "null" }
          ]
        }
      )
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::AutoCategorizer.new(
      client,
      model: "claude-haiku-4-5",
      transactions: @transactions,
      user_categories: @user_categories
    ).auto_categorize

    assert_nil result.find { |r| r.transaction_id == "txn_1" }.category_name
    assert_nil result.find { |r| r.transaction_id == "txn_2" }.category_name
  end

  test "raises when no tool_use block is present in the response" do
    fake_response = build_response(content: [ text_block("No tool use") ])
    client = stub_client(fake_response)

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::AutoCategorizer.new(
        client,
        model: "claude-haiku-4-5",
        transactions: @transactions,
        user_categories: @user_categories
      ).auto_categorize
    end

    assert_match(/did not invoke report_categorizations/i, err.message)
  end

  private
    def stub_client(response, expect_request: nil)
      messages = mock
      if expect_request
        messages.expects(:create).with do |params|
          expect_request.call(params)
          true
        end.returns(response)
      else
        messages.stubs(:create).returns(response)
      end
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def build_response(content:, usage: { input_tokens: 50, output_tokens: 25 })
      OpenStruct.new(
        id: "msg_test",
        model: "claude-haiku-4-5",
        content: content,
        usage: OpenStruct.new(
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens]
        )
      )
    end

    def text_block(text)
      OpenStruct.new(type: :text, text: text)
    end

    def tool_use_block(id:, name:, input:)
      OpenStruct.new(type: :tool_use, id: id, name: name, input: input)
    end
end
