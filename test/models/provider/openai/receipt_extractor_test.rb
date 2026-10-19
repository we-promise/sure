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

  test "renders a scanned PDF to page images for the vision endpoint" do
    Pdf::TextExtractor.expects(:pages).returns([ "" ])
    Provider::Openai::ReceiptExtractor.any_instance.expects(:render_pdf_pages).returns(%w[page1 page2])
    client = capturing_client(RECEIPT_JSON)

    result = build_extractor(client, content_type: "application/pdf").extract

    parts = client.last_params[:messages].last[:content]
    urls = parts.select { |part| part[:type] == "image_url" }.map { |part| part.dig(:image_url, :url) }
    assert_equal [ "data:image/png;base64,page1", "data:image/png;base64,page2" ], urls
    assert_nil client.last_params[:response_format]
    assert_equal 2, result.line_items.size
  end

  test "sends at most MAX_PDF_PAGES page images" do
    Pdf::TextExtractor.expects(:pages).returns([ "" ])
    pages = Array.new(Provider::Openai::ReceiptExtractor::MAX_PDF_PAGES + 2) { |i| "page#{i}" }
    Provider::Openai::ReceiptExtractor.any_instance.expects(:render_pdf_pages).returns(pages)
    client = capturing_client(RECEIPT_JSON)

    build_extractor(client, content_type: "application/pdf").extract

    images = client.last_params[:messages].last[:content].count { |part| part[:type] == "image_url" }
    assert_equal Provider::Openai::ReceiptExtractor::MAX_PDF_PAGES, images
  end

  test "raises when a PDF has neither text nor renderable pages" do
    Pdf::TextExtractor.expects(:pages).returns([ "" ])
    Provider::Openai::ReceiptExtractor.any_instance.expects(:render_pdf_pages).returns([])
    client = capturing_client(RECEIPT_JSON)

    assert_raises(Provider::Openai::Error) do
      build_extractor(client, content_type: "application/pdf").extract
    end
    assert_nil client.last_params, "no request is sent"
  end

  test "renders a real image-only PDF with pdftoppm" do
    skip "pdftoppm (poppler-utils) is not installed" unless system("which pdftoppm > /dev/null 2>&1")

    pdf = image_only_pdf
    assert_equal "", Pdf::TextExtractor.pages(pdf).join.strip, "fixture has no text layer"

    pages = build_extractor(capturing_client(RECEIPT_JSON), content_type: "application/pdf", file_content: pdf)
      .send(:render_pdf_pages, pdf)

    assert_equal 1, pages.size
    assert Base64.strict_decode64(pages.first).start_with?("\x89PNG".b)
  end

  test "reads a text PDF without a vision-capable model" do
    Pdf::TextExtractor.expects(:pages).returns([ "HAMMER 30.00\nNAILS 20.00" ])
    client = capturing_client(RECEIPT_JSON)

    result = build_extractor(client, content_type: "application/pdf", vision: false).extract

    assert_equal 2, result.line_items.size
    assert_kind_of String, client.last_params[:messages].last[:content]
  end

  test "needs a vision-capable model for photos and scanned PDFs" do
    client = capturing_client(RECEIPT_JSON)

    error = assert_raises(Provider::Openai::Error) do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes", vision: false).extract
    end
    assert_match "vision-capable", error.message

    Pdf::TextExtractor.expects(:pages).returns([ "" ])
    Provider::Openai::ReceiptExtractor.any_instance.expects(:render_pdf_pages).never
    error = assert_raises(Provider::Openai::Error) do
      build_extractor(client, content_type: "application/pdf", vision: false).extract
    end
    assert_match "vision-capable", error.message
    assert_nil client.last_params, "no request is sent"
  end

  test "keeps receipt content out of the error when the response is not JSON" do
    client = capturing_client("Hammer 30.00 at Hardware store, card ending 4242")

    error = assert_raises(Provider::Openai::Error) do
      build_extractor(client, content_type: "image/png", file_content: "png-bytes").extract
    end
    assert_no_match(/Hammer|Hardware|4242/, error.message)
  end

  test "raises for an unsupported file type" do
    assert_raises(Provider::Openai::Error) do
      build_extractor(capturing_client(RECEIPT_JSON), content_type: "text/plain").extract
    end
  end

  private
    # A one-page PDF with a filled rectangle and no text layer.
    def image_only_pdf
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
        "<< /Length 18 >>\nstream\n10 10 100 100 re f\nendstream"
      ]
      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |body, index|
        offset = pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{body}\nendobj\n"
        offset
      end
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      pdf.b
    end

    def build_extractor(client, content_type:, file_content: "%PDF-1.4 fake".b, vision: true)
      Provider::Openai::ReceiptExtractor.new(
        client,
        model: "gpt-4.1",
        file_content: file_content,
        content_type: content_type,
        json_mode: "json_object",
        vision: vision
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
