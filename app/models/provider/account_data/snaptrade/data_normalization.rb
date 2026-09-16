# Provider meanings and financial identity deliberately remain separate. For
# example, reinvestment and assignment remain Trade rows, while stock dividends
# and unknown nontrade types retain the legacy Transaction representation.
module Provider::AccountData::Snaptrade::DataNormalization
  LABELS = {
    "BUY" => "Buy", "SELL" => "Sell", "DIVIDEND" => "Dividend", "DIV" => "Dividend",
    "CONTRIBUTION" => "Contribution", "WITHDRAWAL" => "Withdrawal", "TRANSFER_IN" => "Transfer",
    "TRANSFER_OUT" => "Transfer", "TRANSFER" => "Transfer", "INTEREST" => "Interest", "FEE" => "Fee", "TAX" => "Fee",
    "REI" => "Reinvestment", "REINVEST" => "Reinvestment", "SPLIT" => "Other", "SPLIT_REVERSE" => "Other",
    "MERGER" => "Other", "SPIN_OFF" => "Other", "STOCK_DIVIDEND" => "Dividend", "JOURNAL" => "Other",
    "CASH" => "Contribution", "CORP_ACTION" => "Other", "OTHER" => "Other", "OPTION_BUY" => "Buy",
    "OPTION_SELL" => "Sell", "EXERCISED" => "Other", "EXPIRED" => "Other", "ASSIGNED" => "Other"
  }.freeze
  TRADE_TYPES = %w[BUY SELL REI REINVEST OPTION_BUY OPTION_SELL EXERCISED ASSIGNED].freeze
  SELL_TYPES = %w[SELL OPTION_SELL ASSIGNED].freeze

  def normalize_activity(raw, account:)
    data = normalized_object(raw)
    source_account = data[:account]
    source_account = normalized_object(source_account)[:id] if source_account.is_a?(Hash)
    raise ArgumentError if source_account.present? && source_account != account[:external_id]
    identity = normalized_id(data[:id])
    type = data.fetch(:type).upcase
    raise ArgumentError if type.blank?
    label = LABELS.fetch(type, "Other")
    date = parsed_date(data[:settlement_date]) || parsed_date(data[:trade_date]) || observed_date
    metadata = { investment_activity_label: label, pending_provided: false }
    if TRADE_TYPES.include?(type)
      symbol_data, ticker = activity_symbol(data)
      raise ArgumentError unless ticker.is_a?(String) && ticker.present?
      quantity = optional_decimal(data[:units]) || optional_decimal(data[:quantity])
      raise ArgumentError unless quantity
      quantity = SELL_TYPES.include?(type) ? -quantity.abs : quantity.abs
      price = optional_decimal(data[:price])
      amount = price ? quantity * price : optional_decimal(data[:amount]) || optional_decimal(data[:trade_value])
      # Legacy import_trade ultimately rejects nil price via Trade validation;
      # its enclosing loop skips that row. Retain it in page evidence instead
      # of inventing a price from the fallback amount.
      raise ArgumentError unless amount && price
      metadata[:allow_zero_quantity] = true if quantity.zero?
      Ingestion::Record.activity(external_id: identity, activity_type: label.downcase, ledger_type: "trade",
        quantity: quantity, price: price, amount: amount,
        currency: currency_code(data[:currency] || symbol_data[:currency], fallback: account[:currency]), date: date,
        name: data[:description] || "#{type} #{ticker}", security: security_metadata(ticker, symbol_data), metadata: metadata)
    else
      amount = optional_decimal(data[:amount]) || optional_decimal(data[:net_amount])
      return nil if amount.nil? || amount.zero?
      amount = case type
      when "WITHDRAWAL", "TRANSFER_OUT", "FEE", "TAX" then amount.abs
      when "CONTRIBUTION", "TRANSFER_IN", "DIVIDEND", "DIV", "INTEREST", "CASH" then -amount.abs
      when "TRANSFER" then -amount
      else amount
      end
      symbol = data[:symbol].is_a?(Hash) ? normalized_object(data[:symbol]) : {}
      ticker = symbol[:symbol] || symbol[:ticker]
      description = data[:description] || (ticker.present? ? "#{label} - #{ticker}" : label)
      Ingestion::Record.activity(external_id: identity, activity_type: label.downcase, ledger_type: "transaction",
        amount: amount, currency: currency_code(data[:currency], fallback: account[:currency]), date: date,
        name: description, metadata: metadata)
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade activity", cause: nil
  end

  def normalize_holding(raw, account:)
    data = normalized_object(raw)
    return nil if unsupported_holding?(data)
    symbol = holding_symbol(data)
    ticker = symbol[:symbol]
    ticker = symbol[:raw_symbol] if ticker.is_a?(Hash)
    raise ArgumentError unless ticker.is_a?(String) && ticker.present?
    quantity, price = decimal(data.fetch(:units)), decimal(data.fetch(:price))
    code = position_currency(data, account[:currency])
    cost_basis = data[:average_purchase_price] || data[:cost_basis]
    metadata = { holding_identity: "security_date_currency", delete_future_holdings: false }
    metadata[:cost_basis] = decimal(cost_basis) if cost_basis.present?
    # Legacy holdings have no external_id. A source observation gets a stable
    # ticker/currency identity; ledger identity stays security/date/currency.
    identity = Digest::SHA256.hexdigest(JSON.generate([ ticker.strip.upcase, code ]))
    Ingestion::Record.holding(external_id: "snaptrade_position_#{identity}", currency: code, date: observed_date,
      quantity: quantity, price: price, amount: quantity * price, security: security_metadata(ticker, symbol), metadata: metadata)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid SnapTrade holding", cause: nil
  end

  # Historical SDK/JSON snapshots may already contain Floats. Keep that explicit
  # conversion at a compatibility boundary; live normalization rejects Floats.
  def normalize_legacy_activity(raw, account:)
    data = legacy_decimal_fields(raw, %w[units quantity price amount net_amount trade_value fee])
    normalize_activity(data, account: account)
  end

  def normalize_legacy_holding(raw, account:)
    data = legacy_decimal_fields(raw, %w[units price average_purchase_price cost_basis])
    normalize_holding(data, account: account)
  end

  private
    def legacy_decimal_fields(raw, fields)
      data = normalized_object(raw).deep_dup
      fields.each { |key| data[key] = BigDecimal(data[key].to_s) if data[key].is_a?(Float) && data[key].finite? }
      data
    end

    def optional_decimal(value)
      value.nil? ? nil : decimal(value)
    end

    def parsed_date(value)
      return value if value.instance_of?(Date)
      return value.to_date if value.is_a?(Time) || value.is_a?(DateTime)
      value.is_a?(String) ? Date.parse(value) : nil
    rescue ArgumentError, TypeError
      nil
    end

    def currency_code(value, fallback: nil)
      value = normalized_object(value)[:code] if value.is_a?(Hash)
      return fallback if value.nil?
      raise ArgumentError unless value.is_a?(String) && value.present?
      # Preserve GBX and supported cryptocurrency denominations as well as fiat.
      Money::Currency.new(value)
      value
    rescue Money::Currency::UnknownCurrencyError
      raise ArgumentError, "Invalid SnapTrade currency"
    end

    def holding_symbol(data)
      return normalized_object(data[:instrument]) if data[:instrument].is_a?(Hash)
      wrapper = data[:symbol].is_a?(Hash) ? normalized_object(data[:symbol]) : {}
      wrapper[:symbol].is_a?(Hash) ? normalized_object(wrapper[:symbol]) : {}
    end

    def activity_symbol(data)
      wrapper = data[:symbol].is_a?(Hash) ? normalized_object(data[:symbol]) : {}
      case wrapper[:symbol]
      when String then [ wrapper, wrapper[:symbol] ]
      when Hash
        symbol = normalized_object(wrapper[:symbol])
        [ symbol, symbol[:symbol].is_a?(Hash) ? symbol[:raw_symbol] : symbol[:symbol] ]
      else [ {}, nil ]
      end
    end

    def position_currency(data, fallback)
      symbol = holding_symbol(data)
      currency_code(data[:currency] || symbol[:currency], fallback: fallback)
    end

    def unsupported_holding?(raw)
      data = normalized_object(raw)
      instrument = data[:instrument]
      instrument.is_a?(Hash) && self.class::UNSUPPORTED_INSTRUMENTS.include?(instrument[:kind].to_s.downcase)
    end

    def security_metadata(ticker, symbol)
      ticker = ticker.strip.upcase
      name = symbol[:description]
      name = ticker if name.blank? || name.is_a?(Hash) || name.match?(/\A(COMMON STOCK|CRYPTOCURRENCY|ETF|MUTUAL FUND)\z/i)
      name = name.titleize if name == name.upcase && name.length > 4
      exchange = symbol[:exchange]
      exchange = normalized_object(exchange)[:mic_code] || normalized_object(exchange)[:id] if exchange.is_a?(Hash)
      code = symbol[:currency]
      code = normalized_object(code)[:code] if code.is_a?(Hash)
      country = { "USD" => "US", "CAD" => "CA", "GBP" => "GB", "GBX" => "GB" }[code]
      { ticker: ticker, name: name, lookup: "ticker_only", repair_malformed_name: true,
        exchange_mic: exchange, country_code: country }.compact
    end

    def suggested_type(data, meta)
      raw_type = data[:raw_type].presence || meta[:type]
      case data[:account_category]
      when "DEPOSIT" then "Depository"
      when "LOC" then raw_type.to_s.gsub(/[^a-z]/i, "").downcase.include?("card") ? "CreditCard" : "Loan"
      else raw_type.to_s.match?(/crypto|bitcoin|ethereum|digital.?asset/i) ? "Crypto" : "Investment"
      end
    end
end
