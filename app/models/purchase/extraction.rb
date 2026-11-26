# What was read from an order email (Ai::Generations::ExtractPurchase), normalized: the date as a
# Date, amounts as BigDecimals, an unknown payment method as "unknown". Items keep string keys, as
# they are stored with the purchase's AI metadata.
Purchase::Extraction = Data.define(
  :is_order, :not_order_reason, :merchant, :order_number, :order_date, :currency, :total,
  :shipping_cost, :discount_total, :payment_method, :items, :receipt_files
) do
  # value: the generation's answer, or the raw output stored in a purchase's ai_metadata.
  # files: how many files were sent; receipt numbers outside them are dropped. nil keeps them all.
  def self.from_ai(value, files: nil)
    value = value.to_h.deep_stringify_keys
    methods = Ai::Generations::ExtractPurchase::PAYMENT_METHODS
    numbers = Array(value["receipt_files"]).map { _1.is_a?(Hash) ? _1["number"] : _1 }
                                           .select { _1.is_a?(Integer) && _1.positive? && (files.nil? || _1 <= files) }.uniq

    new(
      is_order: value["is_order"] == true,
      not_order_reason: value["not_order_reason"].presence,
      merchant: value["merchant"].presence,
      order_number: value["order_number"].to_s.strip.presence,
      order_date: ReceiptScan::Extraction.date(value["order_date"]),
      currency: value["currency"].to_s.upcase.presence,
      total: ReceiptScan::Extraction.decimal(value["total"]),
      shipping_cost: ReceiptScan::Extraction.decimal(value["shipping_cost"]),
      discount_total: ReceiptScan::Extraction.decimal(value["discount_total"]),
      payment_method: value["payment_method"].to_s.in?(methods) ? value["payment_method"].to_s : "unknown",
      items: Array(value["items"]).map { _1.to_h.stringify_keys },
      receipt_files: numbers
    )
  end
end
