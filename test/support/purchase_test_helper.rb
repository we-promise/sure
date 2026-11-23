# Builds order-email extractions and email purchases for purchase tests: an Amazon.com order in
# USD (the currency of the fixture accounts) unless overridden.
module PurchaseTestHelper
  def build_purchase_extraction(**overrides)
    Provider::LlmConcept::PurchaseExtraction.new(**{
      is_order: true,
      not_order_reason: nil,
      merchant: "Amazon.com",
      order_number: "112-1234567-1234567",
      order_date: Date.current - 2.days,
      currency: "USD",
      total: BigDecimal("249.99"),
      shipping_cost: BigDecimal("20.00"),
      discount_total: BigDecimal("0"),
      payment_method: "card",
      items: [
        { "name" => "HEPA filter", "quantity" => "2", "unit_price" => "39.99", "amount" => "79.98", "category_name" => "Food & Drink", "seller" => "HomeParts LLC" },
        { "name" => "Travel mug", "quantity" => "1", "unit_price" => "150.01", "amount" => "150.01", "category_name" => nil, "seller" => "Amazon.com" }
      ],
      confidence: {},
      notes: nil,
      receipt_files: []
    }.merge(overrides))
  end

  def create_email_purchase(user: users(:family_admin), fixture: "amazon_manual_forward.eml")
    purchase = Purchase.create!(family: user.family, user:, source: :email, status: :processing)
    purchase.original_email.attach(io: file_fixture("purchase_emails/#{fixture}").open, filename: "order.eml", content_type: "message/rfc822")
    purchase
  end

  def stub_purchase_provider(extraction = build_purchase_extraction, success: true, error: nil)
    provider = stub(supports_purchase_extraction?: true, default_model: "claude-test")
    response = Provider::Response.new(success?: success, data: success ? extraction : nil, error:)
    provider.stubs(:extract_purchase).returns(response)
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider
  end

  # A valid PDF with the given number of blank pages, padded with an unused stream so it passes
  # the minimum attachment size.
  def build_pdf(pages: 1, padding: 25_000)
    page_ids = (0...pages).map { |index| 4 + index }
    objects = {
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Kids [#{page_ids.map { "#{_1} 0 R" }.join(" ")}] /Count #{pages} >>",
      3 => "<< /Length #{padding} >>\nstream\n#{"x" * padding}\nendstream"
    }
    page_ids.each { |id| objects[id] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>" }

    pdf = +"%PDF-1.4\n"
    offsets = {}
    objects.sort.each do |id, body|
      offsets[id] = pdf.bytesize
      pdf << "#{id} 0 obj\n#{body}\nendobj\n"
    end
    xref_at = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.sort.each { |_, offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    pdf
  end
end
