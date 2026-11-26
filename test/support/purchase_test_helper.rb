# Builds order-email extractions and email purchases for purchase tests: an Amazon.com order in
# USD (the currency of the fixture accounts) unless overridden.
module PurchaseTestHelper
  def build_purchase_extraction(**overrides)
    Purchase::Extraction.new(**{
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
      receipt_files: []
    }.merge(overrides))
  end

  # An extraction as the model answers it.
  def purchase_ai_answer(extraction = build_purchase_extraction)
    extraction.to_h.transform_values do |value|
      case value
      when BigDecimal then value.to_f
      when Date then value.iso8601
      else value
      end
    end.merge(receipt_files: extraction.receipt_files.map { { number: _1 } })
  end

  def create_email_purchase(user: users(:family_admin), fixture: "amazon_manual_forward.eml")
    purchase = Purchase.create!(family: user.family, user:, source: :email, status: :processing)
    purchase.original_email.attach(io: file_fixture("purchase_emails/#{fixture}").open, filename: "order.eml", content_type: "message/rfc822")
    purchase
  end

  # Answers the order email's reading with the extraction, or fails it with the error; returns
  # the requests sent.
  def stub_purchase_extraction(extraction = build_purchase_extraction, error: nil)
    error ? stub_ai(:extract_purchase, raises: error) : stub_ai(:extract_purchase, returns: purchase_ai_answer(extraction))
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
