require "test_helper"
require "ostruct"

class Provider::Anthropic::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "sends PDF as native document content block and parses tool response" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_document_analysis",
        input: {
          "document_type" => "bank_statement",
          "summary" => "Bank of Example, Mar 2026 statement.",
          "extracted_data" => {
            "institution_name" => "Bank of Example",
            "statement_period_start" => "2026-03-01",
            "statement_period_end" => "2026-03-31",
            "transaction_count" => 42,
            "opening_balance" => 1000.0,
            "closing_balance" => 1500.0,
            "currency" => "USD",
            "account_holder" => "Account Holder"
          }
        }
      )
    ])
    captured = nil
    client = stub_client(fake_response) { |params| captured = params }

    result = Provider::Anthropic::PdfProcessor.new(
      client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).process

    document_block = captured[:messages].first[:content].first
    assert_equal "document", document_block[:type]
    assert_equal "application/pdf", document_block[:source][:media_type]
    assert_equal "base64", document_block[:source][:type]
    assert_equal Base64.strict_encode64(@pdf_content), document_block[:source][:data]

    assert_equal "report_document_analysis", captured[:tool_choice][:name]
    assert captured[:tool_choice][:disable_parallel_tool_use]

    assert_equal "bank_statement", result.document_type
    assert_equal "Bank of Example, Mar 2026 statement.", result.summary
    assert_equal 42, result.extracted_data["transaction_count"]
  end

  test "normalizes unknown document_type to other" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_2",
        name: "report_document_analysis",
        input: {
          "document_type" => "alien_invasion_form",
          "summary" => "Unknown.",
          "extracted_data" => {}
        }
      )
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::PdfProcessor.new(
      client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).process

    assert_equal "other", result.document_type
  end

  test "raises when pdf_content is blank" do
    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::PdfProcessor.new(
        mock,
        model: "claude-sonnet-4-6",
        pdf_content: ""
      ).process
    end
    assert_match(/PDF content is required/i, err.message)
  end

  test "raises before any API call when pdf_content exceeds the 32 MB limit" do
    oversized = "a".b * (Provider::Anthropic::PdfProcessor::MAX_PDF_BYTES + 1)
    client = mock
    client.expects(:messages).never

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::PdfProcessor.new(
        client,
        model: "claude-sonnet-4-6",
        pdf_content: oversized
      ).process
    end
    assert_match(/exceeds Anthropic's 32 MB limit/i, err.message)
  end

  private
    def stub_client(response)
      messages = mock
      messages.expects(:create).with do |params|
        yield(params) if block_given?
        true
      end.returns(response)
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def build_response(content:, usage: { input_tokens: 800, output_tokens: 200 })
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
