require "test_helper"
require "ostruct"

class Provider::Anthropic::ReceiptExtractorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @jpeg = { data: "\xFF\xD8jpeg".b, content_type: "image/jpeg" }
    @pdf = { data: "%PDF-1.4 fake".b, content_type: "application/pdf" }
  end

  test "parses tool output into ReceiptExtraction" do
    client = stub_client(build_response(input: receipt_input))

    result = extractor(client, files: [ @jpeg ]).extract

    assert_instance_of Provider::LlmConcept::ReceiptExtraction, result
    assert_equal "receipt", result.document_kind
    assert_equal "BIEDRONKA", result.merchant
    assert_equal BigDecimal("48.97"), result.total
    assert_equal Date.new(2026, 11, 14), result.date
    assert_nil result.due_date
    assert_equal "PLN", result.currency
    assert_equal "card", result.payment_method
    assert_equal 3, result.line_items.size
    assert_equal({ "name" => "SER GOUDA", "quantity" => "1", "amount" => "12.99", "discount" => "0", "category_name" => "Groceries" },
                 result.line_items.first)
  end

  test "sends images as image blocks and pdf as document block" do
    captured = nil
    client = stub_client(build_response(input: receipt_input)) { |params| captured = params }

    extractor(client, files: [ @jpeg, @pdf ]).extract

    image_block, document_block = captured[:messages].first[:content].first(2)
    assert_equal "image", image_block[:type]
    assert_equal({ type: "base64", media_type: "image/jpeg", data: Base64.strict_encode64(@jpeg[:data]) }, image_block[:source])
    assert_equal "document", document_block[:type]
    assert_equal "application/pdf", document_block[:source][:media_type]
    assert_equal "report_receipt", captured[:tool_choice][:name]
  end

  test "includes category names in prompt" do
    captured = nil
    client = stub_client(build_response(input: receipt_input)) { |params| captured = params }

    extractor(client, files: [ @jpeg ], category_names: [ "Groceries", "Household" ]).extract

    prompt_text = captured[:messages].first[:content].last[:text]
    assert_includes prompt_text, "Groceries"
    assert_includes prompt_text, "Household"
    category_schema = captured[:tools].first[:input_schema][:properties][:line_items][:items][:properties][:category_name]
    assert_equal [ "Groceries", "Household", nil ], category_schema[:enum]
  end

  test "tells the model to return refunds as a negative total" do
    captured = nil
    client = stub_client(build_response(input: receipt_input)) { |params| captured = params }

    extractor(client, files: [ @jpeg ]).extract

    system_text = Array(captured[:system_]).map { _1.is_a?(Hash) ? _1[:text] : _1.to_s }.join
    assert_match(/ZWROT/, system_text)
    assert_match(/negative total/i, system_text)
  end

  test "raises on oversize request" do
    huge = { data: "a".b * (Provider::Anthropic::ReceiptExtractor::MAX_FILES_BYTES + 1), content_type: "image/jpeg" }

    assert_raises(Provider::Anthropic::Error) { extractor(mock, files: [ huge ]).extract }
  end

  test "records usage with operation extract_receipt" do
    client = stub_client(build_response(input: receipt_input))

    assert_difference -> { @family.llm_usages.where(operation: "extract_receipt").count }, 1 do
      extractor(client, files: [ @jpeg ]).extract
    end
  end

  test "unparseable total and date become nil" do
    client = stub_client(build_response(input: receipt_input.merge("total" => "abc", "date" => "14.11.2026")))

    result = extractor(client, files: [ @jpeg ]).extract

    assert_nil result.total
    assert_nil result.date
  end

  private
    def extractor(client, files:, category_names: [ "Groceries" ])
      Provider::Anthropic::ReceiptExtractor.new(client, model: "claude-sonnet-4-6", files:, category_names:, family: @family)
    end

    def receipt_input
      {
        "document_kind" => "receipt",
        "merchant" => "BIEDRONKA",
        "nip" => "7791011327",
        "date" => "2026-11-14",
        "due_date" => nil,
        "total" => "48.97",
        "currency" => "PLN",
        "payment_method" => "card",
        "vat_breakdown" => [ { "letter" => "A", "rate" => "23", "net" => "10.00", "vat" => "2.30", "gross" => "12.30" } ],
        "line_items" => [
          { "name" => "SER GOUDA", "quantity" => "1", "amount" => "12.99", "discount" => "0", "category_name" => "Groceries" },
          { "name" => "MLEKO", "quantity" => "2", "amount" => "7.98", "discount" => "0", "category_name" => "Groceries" },
          { "name" => "PLYN", "quantity" => "1", "amount" => "28.00", "discount" => "0", "category_name" => nil }
        ],
        "confidence" => { "total" => 0.95 },
        "raw_text" => "PARAGON FISKALNY"
      }
    end

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

    def build_response(input:)
      OpenStruct.new(
        id: "msg_test",
        model: "claude-sonnet-4-6",
        stop_reason: "tool_use",
        content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: "report_receipt", input: input) ],
        usage: OpenStruct.new(input_tokens: 1500, output_tokens: 400)
      )
    end
end
