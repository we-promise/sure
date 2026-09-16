# No live endpoint currently supplies these activities. These pure normalizers
# allow the migration/replay path to preserve every historical cached movement.
module Provider::AccountData::IndexaCapital::ActivityNormalization
  ACTIVITY_LABELS = { "BUY" => "Buy", "SELL" => "Sell", "DIVIDEND" => "Dividend", "DIV" => "Dividend",
    "CONTRIBUTION" => "Contribution", "WITHDRAWAL" => "Withdrawal", "TRANSFER_IN" => "Transfer", "TRANSFER_OUT" => "Transfer",
    "TRANSFER" => "Transfer", "INTEREST" => "Interest", "FEE" => "Fee", "TAX" => "Fee", "REINVEST" => "Reinvestment",
    "SPLIT" => "Other", "MERGER" => "Other", "OTHER" => "Other" }.freeze

  def normalize_activity(raw, account:)
    data = normalized_object(raw)
    type = (data[:type] || data[:activity_type]).to_s.upcase
    raise ArgumentError if type.blank?
    id = normalized_id(data[:id] || data[:transaction_id])
    label = ACTIVITY_LABELS.fetch(type, "Other")
    date_value = data[:settlement_date].presence || data[:trade_date].presence || data[:date].presence
    date = date_value ? date_in_zone(date_value) : @observed_at.to_date
    currency_value = data[:currency].is_a?(Hash) ? data.dig(:currency, :code) : data[:currency]
    currency = known_currency(currency_value) || account[:currency] || "EUR"
    if %w[BUY SELL REINVEST].include?(type)
      ticker = normalized_id(data[:symbol] || data[:ticker]).strip.upcase
      quantity = decimal(data[:units] || data[:quantity]).abs
      quantity = -quantity if type == "SELL"
      price = data[:price].nil? ? nil : decimal(data[:price])
      amount = price ? quantity * price : decimal(data[:amount] || data[:trade_value])
      Ingestion::Record.activity(external_id: id, name: data[:description].presence || "#{type} #{ticker}", currency: currency,
        date: date, amount: amount, activity_type: type == "SELL" ? "sell" : "buy", quantity: quantity, price: price,
        security: security_descriptor(ticker, data), metadata: { investment_activity_label: label })
    else
      amount = decimal(data[:amount] || data[:net_amount])
      amount = amount.abs if %w[WITHDRAWAL TRANSFER_OUT FEE TAX].include?(type)
      amount = -amount.abs if %w[CONTRIBUTION TRANSFER_IN DIVIDEND DIV INTEREST].include?(type)
      symbol = data[:symbol] || data[:ticker]
      activity_type = { "DIVIDEND" => "dividend", "DIV" => "dividend", "CONTRIBUTION" => "contribution", "WITHDRAWAL" => "withdrawal",
        "TRANSFER_IN" => "transfer", "TRANSFER_OUT" => "transfer", "TRANSFER" => "transfer", "INTEREST" => "interest", "FEE" => "fee", "TAX" => "fee" }.fetch(type, "other")
      Ingestion::Record.activity(external_id: id, currency: currency, date: date, amount: amount, activity_type: activity_type,
        name: data[:description].presence || (symbol.present? ? "#{label} - #{symbol}" : label),
        metadata: { investment_activity_label: label })
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital activity", cause: nil
  end

  def normalize_legacy_activity(raw, account:)
    data = normalized_object(raw).deep_dup
    %i[amount net_amount trade_value units quantity price].each { |field| data[field] = legacy_float_decimal(data[field]) if data.key?(field) }
    normalize_activity(data, account: account)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Indexa Capital activity", cause: nil
  end
end
