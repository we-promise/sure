# What was read from a receipt (Ai::Generations::ExtractReceipt), normalized: dates as Dates,
# the total as a BigDecimal, unknown kinds and payment methods as "other" and "unknown". VAT rows
# and line items keep string keys, as they are stored on the transaction.
ReceiptScan::Extraction = Data.define(
  :document_kind, :merchant, :nip, :date, :due_date, :total, :currency, :payment_method, :vat_breakdown, :line_items
) do
  def self.from_ai(value)
    value = value.to_h.deep_stringify_keys
    kinds = Ai::Generations::ExtractReceipt::DOCUMENT_KINDS
    methods = Ai::Generations::ExtractReceipt::PAYMENT_METHODS

    new(
      document_kind: value["document_kind"].to_s.in?(kinds) ? value["document_kind"].to_s : "other",
      merchant: value["merchant"].presence,
      nip: value["nip"].to_s.gsub(/\D/, "").presence,
      date: date(value["date"]),
      due_date: date(value["due_date"]),
      total: decimal(value["total"]),
      currency: value["currency"].to_s.upcase.presence,
      payment_method: value["payment_method"].to_s.in?(methods) ? value["payment_method"].to_s : "unknown",
      vat_breakdown: Array(value["vat_breakdown"]).map { _1.to_h.stringify_keys },
      line_items: Array(value["line_items"]).map { _1.to_h.stringify_keys }
    )
  end

  def self.date(value)
    Date.strptime(value.to_s, "%Y-%m-%d")
  rescue Date::Error
    nil
  end

  # A number, or a decimal string with a dot or a comma ("12.99", "12,99"); nil otherwise.
  def self.decimal(value)
    text = value.is_a?(Numeric) ? value.to_s : value.to_s.strip.tr(",", ".")
    BigDecimal(text) if text.match?(/\A-?\d+(\.\d+)?(e-?\d+)?\z/i)
  end
end
