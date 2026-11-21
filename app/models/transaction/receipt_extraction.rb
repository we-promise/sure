module Transaction::ReceiptExtraction
  ReceiptLineItem = Data.define(:name, :amount)
  # `tax` and `discount` are receipt-level totals as positive numbers; any of
  # the numeric fields is nil when the receipt does not show it.
  ReceiptExtraction = Data.define(:merchant_name, :currency, :line_items, :tax, :discount, :total) do
    # Builds an extraction from the model's JSON (string or symbol keys),
    # dropping lines without a name or a readable amount.
    def self.from_response(parsed)
      parsed = parsed.to_h.with_indifferent_access

      line_items = Array(parsed[:line_items]).filter_map do |item|
        next unless item.is_a?(Hash)

        item = item.to_h.with_indifferent_access
        amount = decimal_or_nil(item[:amount])
        name = item[:name].to_s.strip
        next if amount.nil? || name.blank?

        ReceiptLineItem.new(name: name.truncate(255), amount: amount)
      end

      new(
        merchant_name: parsed[:merchant_name].presence,
        currency: parsed[:currency].presence&.to_s&.upcase,
        line_items: line_items,
        tax: decimal_or_nil(parsed[:tax]),
        discount: decimal_or_nil(parsed[:discount])&.abs,
        total: decimal_or_nil(parsed[:total])
      )
    end

    def self.decimal_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      decimal = BigDecimal(value.to_s.strip)
      decimal.finite? ? decimal : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
