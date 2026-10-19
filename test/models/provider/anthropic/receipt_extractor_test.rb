require "test_helper"
require "ostruct"

class Provider::Anthropic::ReceiptExtractorTest < ActiveSupport::TestCase
  RECEIPT_INPUT = {
    "merchant_name" => "Hardware store",
    "currency" => "usd",
    "line_items" => [
      { "name" => "Hammer", "amount" => 30.0 },
      { "name" => "Nails", "amount" => 20 },
      { "name" => "", "amount" => 5 }
    ],
    "tax" => 4.0,
    "discount" => -2.0,
    "total" => 52.0
  }.freeze

  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "sends a text PDF as text and parses the tool response" do
    Pdf::TextExtractor.expects(:pages).returns([ "HAMMER 30.00\nNAILS 20.00\nTAX 4.00" ])
    captured = nil
    client = stub_client(tool_response(RECEIPT_INPUT)) { |params| captured = params }

    result = build_extractor(client, content_type: "application/pdf").extract

    blocks = captured[:messages].first[:content]
    assert_equal [ "text" ], blocks.map { |block| block[:type] }
    assert_match "HAMMER 30.00", blocks.first[:text]
    assert_equal({ type: "tool", name: "report_receipt", disable_parallel_tool_use: true }, captured[:tool_choice])

    assert_equal "Hardware store", result.merchant_name
    assert_equal "USD", result.currency
    assert_equal [ [ "Hammer", BigDecimal("30") ], [ "Nails", BigDecimal("20") ] ], result.line_items.map { |i| [ i.name, i.amount ] }
    assert_equal BigDecimal("4"), result.tax
    assert_equal BigDecimal("2"), result.discount, "a discount is reported as a positive number"
    assert_equal BigDecimal("52"), result.total
  end

  test "sends a scanned PDF as a native document block" do
    Pdf::TextExtractor.expects(:pages).returns([ "", "  " ])
    captured = nil
    client = stub_client(tool_response(RECEIPT_INPUT)) { |params| captured = params }

    result = build_extractor(client, content_type: "application/pdf").extract

    document = captured[:messages].first[:content].first
    assert_equal "document", document[:type]
    assert_equal({ type: "base64", media_type: "application/pdf", data: Base64.strict_encode64(@pdf_content) }, document[:source])
    assert_equal 2, result.line_items.size
  end

  test "sends a photo as a native image block" do
    captured = nil
    client = stub_client(tool_response(RECEIPT_INPUT)) { |params| captured = params }

    build_extractor(client, content_type: "image/jpg", file_content: "jpg-bytes").extract

    image = captured[:messages].first[:content].first
    assert_equal "image", image[:type]
    assert_equal "image/jpeg", image.dig(:source, :media_type), "image/jpg is sent as Anthropic's image/jpeg"
    assert_equal Base64.strict_encode64("jpg-bytes"), image.dig(:source, :data)
  end

  test "records usage for the family" do
    family = families(:dylan_family)
    client = stub_client(tool_response(RECEIPT_INPUT))

    assert_difference -> { family.llm_usages.count }, 1 do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes", family: family).extract
    end

    assert_equal "extract_receipt_vision", family.llm_usages.order(:created_at).last.operation
  end

  test "raises when the model does not call the tool" do
    client = stub_client(OpenStruct.new(content: [ OpenStruct.new(type: :text, text: "no") ], usage: nil))

    assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes").extract
    end
  end

  test "reads a text PDF without a vision-capable model" do
    Pdf::TextExtractor.expects(:pages).returns([ "HAMMER 30.00" ])
    captured = nil
    client = stub_client(tool_response(RECEIPT_INPUT)) { |params| captured = params }

    build_extractor(client, content_type: "application/pdf", vision: false).extract

    assert_equal [ "text" ], captured[:messages].first[:content].map { |block| block[:type] }
  end

  test "needs a vision-capable model for photos and scanned PDFs" do
    client = mock
    client.expects(:messages).never

    error = assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes", vision: false).extract
    end
    assert_match "vision-capable", error.message

    Pdf::TextExtractor.expects(:pages).returns([ "" ])
    error = assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "application/pdf", vision: false).extract
    end
    assert_match "vision-capable", error.message
  end

  test "keeps receipt content out of the error when the tool input is not JSON" do
    client = stub_client(tool_response("{\"merchant_name\": \"Hardware store\", \"line_items\": [Hammer"))

    error = assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes").extract
    end
    assert_no_match(/Hammer|Hardware/, error.message)
  end

  test "rejects unsupported and oversized files before calling the API" do
    client = mock
    client.expects(:messages).never

    assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "text/plain", file_content: "hello").extract
    end

    oversized = "a".b * (Provider::Anthropic::ReceiptExtractor::MAX_IMAGE_BYTES + 1)
    error = assert_raises(Provider::Anthropic::Error) do
      build_extractor(client, content_type: "image/png", file_content: oversized).extract
    end
    assert_match(/5 MB/, error.message)
  end

  private
    def build_extractor(client, content_type:, file_content: @pdf_content, family: nil, vision: true)
      Provider::Anthropic::ReceiptExtractor.new(
        client,
        model: "claude-sonnet-4-6",
        file_content: file_content,
        content_type: content_type,
        family: family,
        vision: vision
      )
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

    def tool_response(input)
      OpenStruct.new(
        id: "msg_test",
        model: "claude-sonnet-4-6",
        content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: "report_receipt", input: input) ],
        usage: OpenStruct.new(input_tokens: 800, output_tokens: 200)
      )
    end
end
