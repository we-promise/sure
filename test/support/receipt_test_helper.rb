# Receipt test data: a clean card receipt in USD (the currency of the fixture accounts) unless
# overridden, as the model answers it (receipt_ai_answer, for stub_ai) or as the processor reads
# it (build_receipt_extraction).
module ReceiptTestHelper
  def receipt_ai_answer(**overrides)
    {
      document_kind: "receipt",
      merchant: "Corner Grocer",
      nip: nil,
      date: (Date.current - 1.day).iso8601,
      due_date: nil,
      total: 50.0,
      currency: "USD",
      payment_method: "card",
      vat_breakdown: [],
      line_items: [
        { name: "Cheese", quantity: 1, amount: 30.0, discount: 0, category_name: "Food & Drink" },
        { name: "Soap", quantity: 1, amount: 20.0, discount: 0, category_name: nil }
      ]
    }.merge(overrides)
  end

  def build_receipt_extraction(**overrides)
    date = overrides.key?(:date) ? overrides[:date]&.iso8601 : (Date.current - 1.day).iso8601
    answer = receipt_ai_answer(**overrides.except(:date, :total), date:)
    ReceiptScan::Extraction.from_ai(answer).then do |extraction|
      overrides.key?(:total) ? extraction.with(total: overrides[:total]) : extraction
    end
  end
end
