require "test_helper"
require "ostruct"

class Provider::Anthropic::BillSetupSuggesterTest < ActiveSupport::TestCase
  setup do
    @charges = [
      { date: "2026-08-03", amount: 15.49, name: "NETFLIX.COM" },
      { date: "2026-09-03", amount: 15.49, name: "NETFLIX.COM" }
    ]
    @categories = [ "Subscriptions", "Utilities" ]
  end

  test "issues a forced tool call and maps the suggestion" do
    client = stub_client(build_response(content: [ suggestion_block ]), expect_request: ->(params) {
      assert_equal "claude-haiku-4-5", params[:model]
      assert_equal({ type: "tool", name: "report_bill_setup", disable_parallel_tool_use: true }, params[:tool_choice])
      assert_equal "report_bill_setup", params[:tools].first[:name]
      assert_not_includes params[:system_], "Do not answer with text."
    })

    result = suggester(client, model: "claude-haiku-4-5").suggest

    assert_suggestion result
  end

  test "sends tool_choice auto to a model that rejects a forced tool" do
    client = stub_client(build_response(content: [ suggestion_block ]), expect_request: ->(params) {
      assert_equal({ type: "auto", disable_parallel_tool_use: true }, params[:tool_choice])
      assert_includes params[:system_], "calling the report_bill_setup tool"
    })

    result = suggester(client, model: "claude-sonnet-5-5").suggest

    assert_suggestion result
  end

  test "raises with the stop reason when the model returns no tool_use" do
    response = build_response(content: [ OpenStruct.new(type: :text, text: "Looks monthly.") ])
    response.stop_reason = :end_turn

    err = assert_raises(Provider::Anthropic::Error) do
      suggester(stub_client(response), model: "claude-sonnet-5-5").suggest
    end

    assert_match(/did not invoke report_bill_setup \(stop_reason: end_turn\)/, err.message)
  end

  private
    def suggester(client, model:)
      Provider::Anthropic::BillSetupSuggester.new(client, model: model, charges: @charges, categories: @categories)
    end

    def assert_suggestion(result)
      assert_equal "Netflix", result.name
      assert_equal 15.49, result.amount
      assert_equal "monthly", result.frequency
      assert_equal 3, result.day_of_month
      assert_equal "Subscriptions", result.category_name
      assert_equal "subscription", result.bill_type
      assert_nil result.autopay
    end

    def suggestion_block
      OpenStruct.new(
        type: :tool_use,
        id: "toolu_1",
        name: "report_bill_setup",
        input: {
          "name" => "Netflix",
          "amount" => 15.49,
          "frequency" => "monthly",
          "day_of_month" => 3,
          "weekday" => nil,
          "month_of_year" => nil,
          "category_name" => "Subscriptions",
          "bill_type" => "subscription",
          "autopay" => nil,
          "confidence" => 0.9,
          "rationale" => "Same charge on the 3rd of each month."
        }
      )
    end

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

    def build_response(content:)
      OpenStruct.new(
        id: "msg_test",
        model: "claude-haiku-4-5",
        content: content,
        usage: OpenStruct.new(input_tokens: 120, output_tokens: 60)
      )
    end
end
