require "test_helper"

class Provider::Openai::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_member)
    @account = accounts(:depository)
  end

  test "process executes tool calls before parsing final json response" do
    client = mock("openai_client")
    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
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

    captured_calls = []
    client.stubs(:chat).with do |parameters:|
      captured_calls << parameters.deep_dup
      true
    end.returns(first_response).then.returns(second_response)

    assert_difference "LlmUsage.count", 1 do
      result = processor.process
      assert_equal "bank_statement", result.document_type
      assert_equal true, result.reconciliation["performed"]
      assert_equal @account.id, result.reconciliation["account_id"]
    end

    assert_equal 2, captured_calls.size

    first_call = captured_calls[0]
    assert first_call[:tools].present?
    assert_equal 2, first_call[:messages].size
    assert_equal "system", first_call[:messages][0][:role]
    assert_equal "user", first_call[:messages][1][:role]

    second_call = captured_calls[1]
    tool_message = second_call[:messages].find { |m| m[:role] == "tool" }
    assert tool_message.present?, "Expected a tool message in the second call"
    assert_equal "call_1", tool_message[:tool_call_id]
    assert_equal "get_accounts", tool_message[:name]
  end

  test "get_transactions augmentation uses balance as of statement end date" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
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

  test "does not expose reconciliation tools without an initiating user" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      max_response_tokens: 4096
    )

    assert_empty processor.send(:reconciliation_tools)
  end

  test "ignores account ids the initiating user cannot access" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
    )

    args = processor.send(:normalize_get_transactions_args, { "account_id" => accounts(:other_asset).id })

    assert_nil args["accounts"]
  end

  test "vision processing marks truncated documents as partial reconciliation" do
    client = mock("openai_client")
    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
    )

    processor.stubs(:convert_pdf_to_images).returns(Array.new(6) { "base64-image" })

    final_json = {
      document_type: "bank_statement",
      summary: "Processed",
      extracted_data: { transaction_count: 10 },
      reconciliation: {
        performed: true,
        balance_match: true,
        new_transactions: [
          { date: "2024-01-02", amount: -12.34, description: "Unseen later page" }
        ],
        missing_transactions: []
      }
    }.to_json

    client.expects(:chat).with do |parameters:|
      text_part = parameters[:messages].last[:content].find { |part| part[:type] == "text" }
      assert_includes text_part[:text], "6 pages total, showing first 5"
      true
    end.returns(
      "choices" => [
        {
          "message" => {
            "content" => final_json
          }
        }
      ],
      "usage" => { "total_tokens" => 50 }
    )

    result = processor.send(:process_with_vision)

    assert_equal false, result.reconciliation["performed"]
    assert_equal true, result.reconciliation["partial_statement"]
    assert_nil result.reconciliation["new_transactions"]
    assert_nil result.reconciliation["missing_transactions"]
  end

  test "tool execution errors return stable payloads without raw exception details" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
    )

    Assistant::Function::GetAccounts.any_instance
      .stubs(:call)
      .raises(StandardError, "secret account details")
    Rails.logger.expects(:warn).with(regexp_matches(/function="get_accounts" error=StandardError/))

    result = processor.send(
      :execute_reconciliation_tool_call,
      {
        "function" => {
          "name" => "get_accounts",
          "arguments" => "{}"
        }
      }
    )

    assert_equal "Tool execution failed", result[:error]
    assert_equal "get_accounts", result[:function_name]
    assert_not result.key?(:details)
  end

  test "unknown reconciliation tool calls are logged" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
    )

    Rails.logger.expects(:warn).with(regexp_matches(/unknown tool call: function="unknown_tool"/))

    result = processor.send(
      :execute_reconciliation_tool_call,
      {
        "function" => {
          "name" => "unknown_tool",
          "arguments" => "{}"
        }
      }
    )

    assert_equal "Unknown tool", result[:error]
    assert_equal "unknown_tool", result[:function_name]
  end

  test "invalid statement end date leaves tool result unchanged and logs" do
    processor = Provider::Openai::PdfProcessor.new(
      stub("openai_client"),
      model: "gpt-4.1",
      pdf_content: "fake-pdf",
      family: @family,
      user: @user,
      max_response_tokens: 4096
    )

    original_result = { "transactions" => [], "total_results" => 0 }
    Rails.logger.expects(:warn).with(regexp_matches(/could not parse statement end date: end_date="not-a-date"/))

    result = processor.send(
      :augment_get_transactions_result_with_balance,
      original_result,
      {
        "accounts" => [ @account.name ],
        "end_date" => "not-a-date"
      }
    )

    assert_equal original_result, result
  end

  test "processing trace payload redacts reconciliation balances and transaction details" do
    result = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Processed",
      document_type: "bank_statement",
      extracted_data: {
        "institution_name" => "Bank",
        "opening_balance" => 100.0,
        "closing_balance" => 200.0,
        "transaction_count" => 2
      },
      reconciliation: {
        "performed" => true,
        "balance_match" => false,
        "statement_closing_balance" => 200.0,
        "synced_closing_balance" => 190.0,
        "statement_transaction_count" => 2,
        "new_transactions" => [
          { "date" => "2024-01-02", "amount" => -12.34, "description" => "Private merchant" }
        ]
      }
    )

    payload = result.trace_payload

    assert_equal "Bank", payload[:extracted_data]["institution_name"]
    assert_equal 2, payload[:extracted_data]["transaction_count"]
    assert_not payload[:extracted_data].key?("opening_balance")
    assert_not payload[:extracted_data].key?("closing_balance")
    assert_equal false, payload[:reconciliation]["balance_match"]
    assert_equal 2, payload[:reconciliation]["statement_transaction_count"]
    assert_not payload[:reconciliation].key?("statement_closing_balance")
    assert_not payload[:reconciliation].key?("synced_closing_balance")
    assert_not payload[:reconciliation].key?("new_transactions")
  end
end
