require "test_helper"

class Provider::Openai::ReceiptExtractorTest < ActiveSupport::TestCase
  RECEIPT_JSON = {
    merchant_name: "Hardware store",
    currency: "usd",
    line_items: [
      { name: "Hammer", amount: 30.0 },
      { name: "Nails", amount: "20.00" },
      { name: "", amount: 5 },
      { name: "Unreadable", amount: "n/a" }
    ],
    tax: 4.0,
    discount: -2.0,
    total: 52.0
  }.to_json

  test "reads a text PDF and parses the line items" do
    Pdf::TextExtractor.expects(:pages).returns([ "HAMMER 30.00\nNAILS 20.00\nTAX 4.00" ])
    client = capturing_client(RECEIPT_JSON)

    result = build_extractor(client, content_type: "application/pdf").extract

    assert_equal "Hardware store", result.merchant_name
    assert_equal "USD", result.currency
    assert_equal [ [ "Hammer", BigDecimal("30") ], [ "Nails", BigDecimal("20") ] ], result.line_items.map { |i| [ i.name, i.amount ] }
    assert_equal BigDecimal("4"), result.tax
    assert_equal BigDecimal("2"), result.discount, "a discount is reported as a positive number"
    assert_equal BigDecimal("52"), result.total

    user_message = client.last_params[:messages].last
    assert_match "HAMMER 30.00", user_message[:content]
  end

  test "sends a photo to the vision endpoint" do
    client = capturing_client(RECEIPT_JSON)

    build_extractor(client, content_type: "image/png", file_content: "png-bytes").extract

    parts = client.last_params[:messages].last[:content]
    image = parts.find { |part| part[:type] == "image_url" }
    assert_equal "data:image/png;base64,#{Base64.strict_encode64("png-bytes")}", image.dig(:image_url, :url)
    assert_nil client.last_params[:response_format]
  end

  test "accepts JSON wrapped in a markdown fence" do
    client = capturing_client("```json\n#{RECEIPT_JSON}\n```")

    result = build_extractor(client, content_type: "image/jpeg").extract

    assert_equal 2, result.line_items.size
  end

  test "raises when the PDF has no text" do
    Pdf::TextExtractor.expects(:pages).returns([ "" ])

    assert_raises(Provider::Openai::Error) do
      build_extractor(capturing_client(RECEIPT_JSON), content_type: "application/pdf").extract
    end
  end

  test "raises for an unsupported file type" do
    assert_raises(Provider::Openai::Error) do
      build_extractor(capturing_client(RECEIPT_JSON), content_type: "text/plain").extract
    end
  end

  private
    def build_extractor(client, content_type:, file_content: "%PDF-1.4 fake".b)
      Provider::Openai::ReceiptExtractor.new(
        client,
        model: "gpt-4.1",
        file_content: file_content,
        content_type: content_type,
        json_mode: "json_object"
      )
    end

    def capturing_client(content)
      client = Object.new
      client.instance_variable_set(:@content, content)
      client.define_singleton_method(:last_params) { @last_params }
      client.define_singleton_method(:chat) do |parameters:|
        @last_params = parameters
        { "choices" => [ { "message" => { "content" => @content } } ], "usage" => { "total_tokens" => 10 } }
      end
      client
    end
end
