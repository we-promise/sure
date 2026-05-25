require "test_helper"

class Provider::Anthropic::ProviderMerchantEnhancerTest < ActiveSupport::TestCase
  setup do
    @merchants = [
      { id: "m1", name: "Walmart" },
      { id: "m2", name: "Local Diner" }
    ]
  end

  test "issues a forced tool call and maps enhancements" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_enhancements",
        input: {
          "merchants" => [
            { "merchant_id" => "m1", "business_url" => "walmart.com" },
            { "merchant_id" => "m2", "business_url" => nil }
          ]
        }
      )
    ])
    client = stub_client(fake_response, expect_request: ->(params) {
      assert_equal "report_enhancements", params[:tool_choice][:name]
    })

    result = Provider::Anthropic::ProviderMerchantEnhancer.new(
      client,
      model: "claude-haiku-4-5",
      merchants: @merchants
    ).enhance_merchants

    assert_equal "walmart.com", result.find { |r| r.merchant_id == "m1" }.business_url
    assert_nil result.find { |r| r.merchant_id == "m2" }.business_url
  end

  test "raises when model returns no tool_use" do
    fake_response = build_response(content: [ OpenStruct.new(type: :text, text: "Nope") ])
    client = stub_client(fake_response)

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::ProviderMerchantEnhancer.new(
        client,
        model: "claude-haiku-4-5",
        merchants: @merchants
      ).enhance_merchants
    end

    assert_match(/did not invoke report_enhancements/i, err.message)
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

    def build_response(content:, usage: { input_tokens: 60, output_tokens: 20 })
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
