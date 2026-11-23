# Builds a Provider::LlmConcept::ReceiptExtraction for receipt tests: a clean card receipt in
# USD (the currency of the fixture accounts) unless overridden.
module ReceiptTestHelper
  def build_receipt_extraction(**overrides)
    Provider::LlmConcept::ReceiptExtraction.new(**{
      document_kind: "receipt",
      merchant: "Corner Grocer",
      nip: nil,
      date: Date.current - 1.day,
      due_date: nil,
      total: BigDecimal("50.00"),
      currency: "USD",
      payment_method: "card",
      vat_breakdown: [],
      line_items: [
        { "name" => "Cheese", "quantity" => "1", "amount" => "30.00", "discount" => "0", "category_name" => "Food & Drink" },
        { "name" => "Soap", "quantity" => "1", "amount" => "20.00", "discount" => "0", "category_name" => nil }
      ],
      confidence: {},
      raw_text: nil
    }.merge(overrides))
  end
end
