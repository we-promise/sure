require "test_helper"
require "ostruct"

class Provider::Anthropic::BankStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "sends PDF as native document and returns normalized transactions + metadata" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_bank_statement",
        input: {
          "bank_name" => "Bank of Example",
          "account_holder" => "Jane Doe",
          "account_number" => "1234",
          "statement_period" => { "start_date" => "2026-03-01", "end_date" => "2026-03-31" },
          "opening_balance" => 1000.0,
          "closing_balance" => 1500.0,
          "transactions" => [
            { "date" => "2026-03-05", "description" => "Coffee", "amount" => -4.5 },
            { "date" => "2026-03-15", "description" => "Salary", "amount" => 3000.0, "reference" => "Payroll Mar" }
          ]
        }
      )
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::BankStatementExtractor.new(
      client: client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).extract

    assert_equal "Bank of Example", result[:bank_name]
    assert_equal "Jane Doe", result[:account_holder]
    assert_equal "1234", result[:account_number]
    assert_equal "2026-03-01", result[:period][:start_date]
    assert_equal "2026-03-31", result[:period][:end_date]
    assert_equal 1000.0, result[:opening_balance]
    assert_equal 1500.0, result[:closing_balance]

    assert_equal 2, result[:transactions].size
    txn1 = result[:transactions].first
    assert_equal "2026-03-05", txn1[:date]
    assert_equal "Coffee", txn1[:name]
    assert_equal(-4.5, txn1[:amount])

    txn2 = result[:transactions].last
    assert_equal "Salary", txn2[:name]
    assert_equal 3000.0, txn2[:amount]
    assert_equal "Payroll Mar", txn2[:notes]
  end

  test "raises when pdf_content is blank" do
    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::BankStatementExtractor.new(
        client: mock,
        model: "claude-sonnet-4-6",
        pdf_content: nil
      ).extract
    end
    assert_match(/PDF content is required/i, err.message)
  end

  test "raises when model omits the tool call" do
    fake_response = build_response(content: [ OpenStruct.new(type: :text, text: "no tool") ])
    client = stub_client(fake_response)

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::BankStatementExtractor.new(
        client: client,
        model: "claude-sonnet-4-6",
        pdf_content: @pdf_content
      ).extract
    end
    assert_match(/did not invoke report_bank_statement/i, err.message)
  end

  test "raises before API call when pdf_content exceeds the 32 MB limit" do
    oversized = "a".b * (Provider::Anthropic::BankStatementExtractor::MAX_PDF_BYTES + 1)
    client = mock
    client.expects(:messages).never

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::BankStatementExtractor.new(
        client: client,
        model: "claude-sonnet-4-6",
        pdf_content: oversized
      ).extract
    end
    assert_match(/exceeds Anthropic's 32 MB limit/i, err.message)
  end

  test "flags result as truncated when stop_reason is max_tokens" do
    fake_response = build_response(
      content: [
        tool_use_block(
          id: "toolu_1",
          name: "report_bank_statement",
          input: { "transactions" => [ { "date" => "2026-03-05", "description" => "Coffee", "amount" => -4.5 } ] }
        )
      ]
    )
    fake_response.stop_reason = :max_tokens
    client = stub_client(fake_response)

    Rails.logger.expects(:warn).with(regexp_matches(/truncated by max_tokens/i))

    result = Provider::Anthropic::BankStatementExtractor.new(
      client: client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).extract

    assert_equal true, result[:truncated]
  end

  private
    def stub_client(response)
      messages = mock
      messages.stubs(:create).returns(response)
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def build_response(content:, usage: { input_tokens: 1500, output_tokens: 400 })
      OpenStruct.new(
        id: "msg_test",
        model: "claude-sonnet-4-6",
        content: content,
        usage: OpenStruct.new(input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens])
      )
    end

    def tool_use_block(id:, name:, input:)
      OpenStruct.new(type: :tool_use, id: id, name: name, input: input)
    end
end
