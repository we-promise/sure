require "test_helper"

class Provider::Anthropic::AutoMerchantDetectorTest < ActiveSupport::TestCase
  setup do
    @transactions = [
      { id: "txn_1", name: "AMZN purchases", classification: "expense" },
      { id: "txn_2", name: "Local diner", classification: "expense" }
    ]
    @user_merchants = [ { id: "m1", name: "Shooters" } ]
  end

  test "issues a forced tool call and maps merchants" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_merchants",
        input: {
          "merchants" => [
            { "transaction_id" => "txn_1", "business_name" => "Amazon", "business_url" => "amazon.com" },
            { "transaction_id" => "txn_2", "business_name" => nil, "business_url" => nil }
          ]
        }
      )
    ])
    client = stub_client(fake_response, expect_request: ->(params) {
      assert_equal "claude-haiku-4-5", params[:model]
      assert_equal "report_merchants", params[:tool_choice][:name]
      assert params[:tool_choice][:disable_parallel_tool_use]
    })

    result = Provider::Anthropic::AutoMerchantDetector.new(
      client,
      model: "claude-haiku-4-5",
      transactions: @transactions,
      user_merchants: @user_merchants
    ).auto_detect_merchants

    txn1 = result.find { |r| r.transaction_id == "txn_1" }
    txn2 = result.find { |r| r.transaction_id == "txn_2" }

    assert_equal "Amazon", txn1.business_name
    assert_equal "amazon.com", txn1.business_url
    assert_nil txn2.business_name
    assert_nil txn2.business_url
  end

  test "normalizes case-insensitive matches against user_merchants" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_merchants",
        input: {
          "merchants" => [
            { "transaction_id" => "txn_1", "business_name" => "shooters", "business_url" => nil }
          ]
        }
      )
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::AutoMerchantDetector.new(
      client,
      model: "claude-haiku-4-5",
      transactions: [ @transactions.first ],
      user_merchants: @user_merchants
    ).auto_detect_merchants

    assert_equal "Shooters", result.first.business_name
  end

  test "raises when model returns no tool_use" do
    fake_response = build_response(content: [ OpenStruct.new(type: :text, text: "I cannot help") ])
    client = stub_client(fake_response)

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::AutoMerchantDetector.new(
        client,
        model: "claude-haiku-4-5",
        transactions: @transactions,
        user_merchants: @user_merchants
      ).auto_detect_merchants
    end

    assert_match(/did not invoke report_merchants/i, err.message)
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

    def build_response(content:, usage: { input_tokens: 100, output_tokens: 40 })
      OpenStruct.new(
        id: "msg_test",
        model: "claude-haiku-4-5",
        content: content,
        usage: OpenStruct.new(input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens])
      )
    end

    def tool_use_block(id:, name:, input:)
      OpenStruct.new(type: :tool_use, id: id, name: name, input: input)
    end
end
