require "test_helper"
require "ostruct"

class Provider::Anthropic::PurchaseExtractorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @text = "Original-From: Allegro\n\nAmount to pay: 1,249.99 PLN"
  end

  test "parses tool output into PurchaseExtraction" do
    client = stub_client(build_response(input: order_input))

    result = extractor(client).extract

    assert_instance_of Provider::LlmConcept::PurchaseExtraction, result
    assert result.is_order
    assert_equal "Allegro", result.merchant
    assert_equal "a1b2", result.order_number
    assert_equal Date.new(2026, 11, 12), result.order_date
    assert_equal "PLN", result.currency
    assert_equal BigDecimal("1249.99"), result.total
    assert_equal BigDecimal("20.00"), result.shipping_cost
    assert_equal BigDecimal("0"), result.discount_total
    assert_equal "blik", result.payment_method
    assert_equal({ "name" => "Filtr HEPA", "quantity" => "2", "unit_price" => "39.99", "amount" => "79.98", "category_name" => "Household", "seller" => "sklep_agd" },
                 result.items.first)
  end

  test "an unknown payment method becomes unknown and bad numbers become nil" do
    client = stub_client(build_response(input: order_input.merge("payment_method" => "paypal", "total" => "1,249.99", "order_date" => "12.11.2026")))

    result = extractor(client).extract

    assert_equal "unknown", result.payment_method
    assert_nil result.total
    assert_nil result.order_date
  end

  test "keeps the reason when the email is not an order" do
    client = stub_client(build_response(input: order_input.merge("is_order" => false, "not_order_reason" => "Shipping notification")))

    result = extractor(client).extract

    assert_not result.is_order
    assert_equal "Shipping notification", result.not_order_reason
  end

  test "sends the email text, category names and the prompt rules" do
    captured = nil
    client = stub_client(build_response(input: order_input)) { |params| captured = params }

    extractor(client, category_names: [ "Household", "Groceries" ]).extract

    prompt_text = captured[:messages].first[:content].map { _1[:text] }.join
    assert_includes prompt_text, "Amount to pay: 1,249.99 PLN"
    assert_includes prompt_text, "Household"
    system_text = Array(captured[:system_]).map { _1.is_a?(Hash) ? _1[:text] : _1.to_s }.join
    assert_match(/not instructions/i, system_text)
    assert_match(/forward/i, system_text)
    assert_match(/free delivery/i, system_text)
    assert_equal "report_purchase", captured[:tool_choice][:name]
    category_schema = captured[:tools].first[:input_schema][:properties][:items][:items][:properties][:category_name]
    assert_equal [ "Household", "Groceries", nil ], category_schema[:enum]
  end

  test "sends attached files as numbered image and document blocks" do
    captured = nil
    client = stub_client(build_response(input: order_input)) { |params| captured = params }
    files = [ { data: "jpeg-bytes", content_type: "image/jpeg", filename: "receipt.jpg" },
              { data: "%PDF-1.4", content_type: "application/pdf", filename: "invoice.pdf" } ]

    extractor(client, files:).extract

    content = captured[:messages].first[:content]
    assert_equal [ "image", "document" ], content.filter_map { _1[:source] && _1[:type] }
    assert_equal Base64.strict_encode64("jpeg-bytes"), content.find { _1[:type] == "image" }[:source][:data]
    texts = content.filter_map { _1[:text] }.join("\n")
    assert_includes texts, "File 1: receipt.jpg"
    assert_includes texts, "File 2: invoice.pdf"
    assert captured[:tools].first[:input_schema][:properties].key?(:receipt_files)
  end

  test "keeps only the numbers of files that were sent as the receipt files" do
    files = [ { data: "a", content_type: "image/jpeg", filename: "a.jpg" }, { data: "b", content_type: "image/jpeg", filename: "b.jpg" } ]
    client = stub_client(build_response(input: order_input.merge("receipt_files" => [ 2, "x", 7, 1, 2 ])))

    assert_equal [ 2, 1 ], extractor(client, files:).extract.receipt_files
  end

  test "cash is a payment method" do
    client = stub_client(build_response(input: order_input.merge("payment_method" => "cash")))

    assert_equal "cash", extractor(client).extract.payment_method
  end

  test "records usage with operation extract_purchase" do
    client = stub_client(build_response(input: order_input))

    assert_difference -> { @family.llm_usages.where(operation: "extract_purchase").count }, 1 do
      extractor(client).extract
    end
  end

  test "provider supports purchase extraction for models with structured output" do
    provider = Provider::Anthropic.new("test-key", model: "claude-sonnet-4-6")

    assert provider.supports_purchase_extraction?
  end

  private
    def extractor(client, category_names: [ "Household" ], files: [])
      Provider::Anthropic::PurchaseExtractor.new(client, model: "claude-sonnet-4-6", text: @text, files:, category_names:, family: @family)
    end

    def order_input
      {
        "is_order" => true,
        "not_order_reason" => nil,
        "merchant" => "Allegro",
        "order_number" => "a1b2",
        "order_date" => "2026-11-12",
        "currency" => "pln",
        "total" => "1249.99",
        "shipping_cost" => "20.00",
        "discount_total" => "0",
        "payment_method" => "blik",
        "items" => [
          { "name" => "Filtr HEPA", "quantity" => "2", "unit_price" => "39.99", "amount" => "79.98", "category_name" => "Household", "seller" => "sklep_agd" }
        ],
        "confidence" => { "total" => 0.9 },
        "notes" => nil,
        "receipt_files" => []
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
        content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: "report_purchase", input: input) ],
        usage: OpenStruct.new(input_tokens: 1500, output_tokens: 400)
      )
    end
end
