require "test_helper"

class Provider::Openai::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "process executes tool calls before parsing final json response" do
    client = mock("openai_client")
    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family
    )

    processor.stubs(:extract_text_from_pdf).returns("Statement text")

    first_response = {
      "choices" => [
        {
          "message" => {
            "content" => "",
            "tool_calls" => [
              {
                "id" => "call_1",
                "type" => "function",
                "function" => {
                  "name" => "get_accounts",
                  "arguments" => "{}"
                }
              }
            ]
          }
        }
      ],
      "usage" => { "total_tokens" => 100, "prompt_tokens" => 60, "completion_tokens" => 40 }
    }

    final_json = {
      document_type: "bank_statement",
      summary: "Processed",
      extracted_data: { institution_name: "Bank" },
      reconciliation: { performed: true, account_id: @account.id, balance_match: true }
    }.to_json

    second_response = {
      "choices" => [
        {
          "message" => {
            "content" => final_json
          }
        }
      ],
      "usage" => { "total_tokens" => 50, "prompt_tokens" => 30, "completion_tokens" => 20 }
    }

    client.expects(:chat).with do |parameters:|
      assert parameters[:tools].present?
      assert_equal 2, parameters[:messages].size
      assert_equal "system", parameters[:messages][0][:role]
      assert_equal "user", parameters[:messages][1][:role]
      true
    end.returns(first_response)

    client.expects(:chat).with do |parameters:|
      tool_message = parameters[:messages].find { |m| m[:role] == "tool" }
      assert tool_message.present?
      assert_equal "call_1", tool_message[:tool_call_id]
      assert_equal "get_accounts", tool_message[:name]
      true
    end.returns(second_response)

    assert_difference "LlmUsage.count", 1 do
      result = processor.process
      assert_equal "bank_statement", result.document_type
      assert_equal true, result.reconciliation["performed"]
      assert_equal @account.id, result.reconciliation["account_id"]
    end
  end

  test "get_transactions augmentation uses balance as of statement end date" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family
    )

    old_date = 20.days.ago.to_date
    new_date = 10.days.ago.to_date
    statement_end_date = 15.days.ago.to_date

    @account.balances.create!(
      date: old_date,
      balance: 111,
      currency: @account.currency,
      start_cash_balance: 111,
      start_non_cash_balance: 0
    )
    @account.balances.create!(
      date: new_date,
      balance: 222,
      currency: @account.currency,
      start_cash_balance: 222,
      start_non_cash_balance: 0
    )

    @account.update!(balance: 999_999)

    result = processor.send(
      :augment_get_transactions_result_with_balance,
      { "transactions" => [], "total_results" => 0 },
      {
        "accounts" => [ @account.name ],
        "start_date" => 25.days.ago.to_date.iso8601,
        "end_date" => statement_end_date.iso8601
      }
    )

    assert_equal old_date.iso8601, result["balance_record_date"]
    assert_equal 111.0, result["balance_as_of_end_date"]
  end
end
