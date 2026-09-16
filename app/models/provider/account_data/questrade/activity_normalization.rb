module Provider::AccountData::Questrade::ActivityNormalization
  CASH_LABELS = { "Deposits" => "Contribution", "Withdrawals" => "Withdrawal", "Dividends" => "Dividend",
    "Interest" => "Interest", "Fees and rebates" => "Fee" }.freeze

  # One trade row can emit a security movement and its separate commission.
  def normalize_activity(raw, account:, identity_digest: nil)
    data = normalized_object(raw)
    check_owner!(data, account)
    digest = identity_digest || activity_digest(data)
    type = data[:type].to_s.strip
    if type == "Trades"
      trade_records(data, account, digest)
    elsif CASH_LABELS.key?(type)
      [ cash_record(data, account, digest, CASH_LABELS.fetch(type)) ]
    elsif %w[Other Transfers].include?(type)
      journal_records(data, account, digest)
    else
      # FX conversions and corporate actions have no legacy accounting mapping.
      # Their evidence remains captured with a counted warning for review.
      []
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade activity", cause: nil
  end

  def normalize_legacy_activity(raw, account:)
    data = normalized_object(raw).deep_dup
    # The old hash used Ruby Float#to_s for numeric JSON caches. Calculate it
    # before exact-value conversion so historical entries keep their identity.
    digest = activity_digest(data, legacy: true)
    %i[quantity price grossAmount commission netAmount].each { |key| data[key] = legacy_decimal(data[key]) if data.key?(key) }
    normalize_activity(data, account: account, identity_digest: digest)
  end

  private
    def activity_digest(data, legacy: false)
      values = %i[transactionDate action symbolId quantity netAmount description].map do |key|
        value = data[key]
        raise ArgumentError if value.is_a?(Float) && (!legacy || !value.finite?)
        if value.is_a?(BigDecimal) && !legacy
          # The old JSON reader decoded decimal JSON numbers as Float before
          # hashing them. Preserve that identifier encoding only; the Record's
          # quantities, prices and amounts still use the exact decimal values.
          # Strings and integer JSON numbers retain their original identity form.
          encoded = value.to_f
          raise ArgumentError unless encoded.finite? && (value.zero? || !encoded.zero?)
          encoded.to_s
        else
          value.to_s
        end
      end
      Digest::SHA256.hexdigest(values.join("|")).first(24)
    end

    def activity_date(data, *keys)
      key = keys.find { |candidate| data[candidate].present? }
      key ? date_in_zone(data[key]) : @observed_at.to_date
    end

    def trade_records(data, account, digest)
      ticker = data[:symbol].to_s.strip
      return [] if ticker.blank?
      quantity = decimal(data[:quantity])
      return [] if quantity.zero?
      sell = data[:action].to_s.casecmp("Sell").zero?
      quantity = sell ? -quantity.abs : quantity.abs
      price = data[:price].nil? ? nil : decimal(data[:price])
      amount = price ? quantity * price : decimal(data[:netAmount]).abs
      date = activity_date(data, :tradeDate, :transactionDate)
      currency = currency_for(data, account)
      records = [ Ingestion::Record.activity(external_id: "questrade_trade_#{digest}", activity_type: sell ? "sell" : "buy",
        quantity: quantity, price: price, amount: amount, currency: currency, date: date,
        name: data[:description].presence || "#{sell ? 'Sell' : 'Buy'} #{ticker}",
        security: security_descriptor(ticker, name: data[:description], currency: data[:currency])) ]
      commission = data[:commission].nil? ? nil : decimal(data[:commission])
      if commission && !commission.zero?
        records << Ingestion::Record.activity(external_id: "questrade_fee_#{digest}", activity_type: "fee", amount: commission.abs,
          currency: currency, date: date, name: "Commission for #{ticker}")
      end
      records
    end

    def journal_records(data, account, digest)
      ticker = data[:symbol].to_s.strip
      return [] if ticker.blank? || data[:quantity].nil?
      quantity = decimal(data[:quantity])
      return [] if quantity.zero?
      [ Ingestion::Record.activity(external_id: "questrade_journal_#{digest}", activity_type: quantity.negative? ? "sell" : "buy",
        quantity: quantity, price: BigDecimal("0"), amount: BigDecimal("0"), currency: currency_for(data, account),
        date: activity_date(data, :tradeDate, :transactionDate), name: data[:description].presence || "Journal #{ticker}",
        security: security_descriptor(ticker, name: data[:description], currency: data[:currency]), metadata: { investment_activity_label: "Transfer" }) ]
    end

    def cash_record(data, account, digest, label)
      ticker = data[:symbol].to_s.strip
      attrs = { external_id: "questrade_cash_#{digest}", activity_type: label.downcase, amount: -decimal(data[:netAmount]),
        currency: currency_for(data, account), date: activity_date(data, :settlementDate, :transactionDate, :tradeDate),
        name: data[:description].presence || (ticker.present? ? "#{label} - #{ticker}" : label) }
      attrs[:security] = security_descriptor(ticker, name: data[:description], currency: data[:currency]) if ticker.present?
      Ingestion::Record.activity(**attrs)
    end
end
