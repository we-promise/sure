module Provider::AccountData::Plaid::InvestmentNormalization
  ACTIVITY_LABELS = { "buy" => "Buy", "sell" => "Sell", "cancel" => "Other", "cash" => "Other", "fee" => "Fee",
    "transfer" => "Transfer", "dividend" => "Dividend", "interest" => "Interest", "contribution" => "Contribution",
    "withdrawal" => "Withdrawal", "dividend reinvestment" => "Reinvestment", "spin off" => "Other", "split" => "Other" }.freeze
  CASH_TYPES = %w[cash fee transfer contribution withdrawal].freeze

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    response = client.get_accounts
    check_item!(response)
    row = checked_rows(normalized_object(response).fetch(:accounts)).find { |value| value[:account_id] == account[:external_id] }
    raise ArgumentError unless row
    record = normalize_account(row, products: products_for(account))
    evidence = { "accounts" => response }
    metadata = (account[:metadata] || {}).with_indifferent_access.except(:accountable_attributes).merge(record[:metadata]).merge(balance_provided: true)
    warnings = []
    complete = true
    cash = record[:cash_balance]
    if record[:account_type] == "investment"
      raise Provider::AccountData::UnsupportedCapability, "Plaid investment product is unavailable" unless @region == "us" && products_for(account).include?("investments")
      holdings_response = client.get_holdings(account_id: account[:external_id])
      check_item!(holdings_response)
      data = normalized_object(holdings_response)
      securities = checked_rows(data.fetch(:securities))
      holdings_value = checked_rows(data.fetch(:holdings)).sum(BigDecimal("0")) do |holding|
        check_account!(holding, account)
        security = source_security(holding[:security_id], securities)
        brokerage_cash?(security) ? BigDecimal("0") : decimal(holding[:quantity]) * decimal(holding[:institution_price])
      end
      cash = record[:balance] - holdings_value
      evidence["holdings"] = holdings_response
    end
    if @region == "us" && products_for(account).include?("liabilities") && liability_kind(record)
      begin
        liability_response = client.get_liabilities(account_id: account[:external_id])
        evidence["liabilities"] = liability_response
        check_item!(liability_response)
        metadata[:accountable_attributes] = normalize_liabilities(liability_response, account: record)
      rescue Provider::Plaid::IngestionClient::Error, Provider::AccountData::InvalidResponse, ArgumentError, KeyError, TypeError, NoMethodError => error
        complete = false
        warnings << { "code" => "liabilities_unavailable" }
        evidence["liabilities_failure"] = { "error_class" => error.class.name }
      end
    end
    normalized = Ingestion::Record.account(**record.attributes.merge(cash_balance: cash, metadata: metadata))
    warnings << { "code" => "negative_investment_cash" } if record[:account_type] == "investment" && cash.negative?
    warnings << { "code" => "negative_investment_value" } if record[:account_type] == "investment" && record[:balance].negative?
    Provider::AccountData::Page.new(records: [ normalized ], complete: complete, mode: "snapshot", evidence: evidence, warnings: warnings)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    return empty_investment_page unless investment_account?(account)
    response = client.get_holdings(account_id: account[:external_id])
    check_item!(response)
    data = normalized_object(response)
    securities = checked_rows(data.fetch(:securities))
    rows = checked_rows(data.fetch(:holdings))
    records = rows.filter_map { |raw| normalize_holding(raw, account: account, securities: securities) }
    Provider::AccountData::Page.new(records: records, complete: true, mode: "delta",
      coverage: { "absence_authoritative" => false }, evidence: { "response" => response },
      warnings: records.size < rows.size ? [ { "code" => "cash_or_unresolved_holdings", "count" => rows.size - records.size } ] : [])
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid holdings", cause: nil
  end

  def normalize_holding(raw, account:, securities:)
    data = normalized_object(raw)
    check_account!(data, account)
    security = source_security(data[:security_id], checked_rows(securities))
    return nil if security.nil? || brokerage_cash?(security)
    quantity, price = decimal(data[:quantity]), decimal(data[:institution_price])
    date = data[:institution_price_as_of].nil? ? @observed_at.to_date : date_in_zone(data[:institution_price_as_of])
    currency = normalized_currency(data[:iso_currency_code], fallback: account[:currency])
    Ingestion::Record.holding(external_id: [ "plaid_holding", account[:external_id], normalized_id(data[:security_id]), date.iso8601, currency ].join(":"),
      quantity: quantity, price: price, amount: quantity * price, currency: currency, date: date,
      security: security_descriptor(security), metadata: { holding_identity: "security_date_currency", delete_future_holdings: false })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid holding", cause: nil
  end

  def normalize_legacy_holding(raw, account:, securities:)
    data = normalized_object(raw).deep_dup
    %i[quantity institution_price institution_value cost_basis].each { |key| data[key] = legacy_decimal(data[key]) if data.key?(key) }
    normalize_holding(data, account: account, securities: securities)
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    return empty_investment_page unless investment_account?(account)
    scope = investment_scope(account, cursor, window)
    response = client.get_investment_transactions_page(start_date: Date.iso8601(scope.fetch("start")), end_date: Date.iso8601(scope.fetch("end")),
      offset: scope.fetch("offset"), account_id: account[:external_id])
    check_item!(response)
    data = normalized_object(response)
    securities = checked_rows(data.fetch(:securities))
    rows = checked_rows(data.fetch(:investment_transactions))
    total = data.fetch(:total_investment_transactions)
    raise ArgumentError unless total.is_a?(Integer) && total >= 0 && (scope["total"].nil? || scope["total"] == total)
    offset = scope.fetch("offset") + rows.size
    raise ArgumentError if offset > total || (rows.empty? && offset < total)
    records = rows.filter_map { |raw| normalize_activity(raw, account: account, securities: securities) }
    complete = offset == total
    next_cursor = Base64.strict_encode64(JSON.generate(scope.merge("offset" => offset, "total" => total))) unless complete
    Provider::AccountData::Page.new(records: records, complete: complete, next_cursor: next_cursor, mode: "delta",
      coverage: { "start" => Date.iso8601(scope.fetch("start")).in_time_zone(@timezone).utc.iso8601,
        "end" => Date.iso8601(scope.fetch("end")).in_time_zone(@timezone).end_of_day.utc.iso8601,
        "absence_authoritative" => false }, evidence: { "response" => response },
      warnings: records.size < rows.size ? [ { "code" => "unresolved_investment_activities", "count" => rows.size - records.size } ] : [])
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid investment activities", cause: nil
  end

  def normalize_activity(raw, account:, securities:)
    data = normalized_object(raw)
    check_account!(data, account)
    id, type = normalized_id(data[:investment_transaction_id]), data[:type]
    label = ACTIVITY_LABELS[type&.downcase] || "Other"
    cash = CASH_TYPES.include?(type)
    attrs = { external_id: id, name: data[:name], currency: normalized_currency(data[:iso_currency_code]), date: date_in_zone(data[:date]),
      activity_type: label == "Reinvestment" ? "buy" : label.downcase, ledger_type: cash ? "transaction" : "trade",
      metadata: { investment_activity_label: label } }
    if cash
      attrs[:amount] = decimal(data[:amount])
    else
      security = source_security(data[:security_id], checked_rows(securities))
      return nil if security.nil? || brokerage_cash?(security)
      reported, amount, price = decimal(data[:quantity]), decimal(data[:amount]), decimal(data[:price])
      quantity = if type == "sell" || amount.negative?
        -reported.abs
      elsif type == "buy" || amount.positive?
        reported.abs
      else
        reported
      end
      attrs.merge!(quantity: quantity, price: price, amount: quantity * price, security: security_descriptor(security))
      if !quantity.zero? && %w[Buy Sell Reinvestment].include?(label)
        attrs[:activity_type] = quantity.negative? ? "sell" : "buy"
      end
      attrs[:metadata][:allow_zero_quantity] = true
    end
    Ingestion::Record.activity(**attrs)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid investment activity", cause: nil
  end

  def normalize_legacy_activity(raw, account:, securities:)
    data = normalized_object(raw).deep_dup
    %i[quantity amount price fees].each { |key| data[key] = legacy_decimal(data[key]) if data.key?(key) }
    normalize_activity(data, account: account, securities: securities)
  end

  def normalize_liabilities(response, account:)
    kind = liability_kind(account)
    return {} unless kind
    liabilities = normalized_object(normalized_object(response).fetch(:liabilities))
    rows = liabilities[kind].nil? ? [] : checked_rows(liabilities[kind])
    rows.each { |row| check_account!(row, account) }
    raise ArgumentError if rows.size > 1
    data = rows.first
    return {} unless data
    attributes = case kind
    when :credit
      aprs = data[:aprs].nil? ? [] : checked_rows(data[:aprs])
      { "minimum_payment" => nullable_decimal(data[:minimum_payment_amount]), "apr" => nullable_decimal(aprs.first&.[](:apr_percentage)) }
    when :mortgage
      rate = data[:interest_rate].nil? ? {} : normalized_object(data[:interest_rate])
      { "rate_type" => rate[:type], "interest_rate" => nullable_decimal(rate[:percentage]) }
    when :student
      origin = data[:origination_date].present? ? date_in_zone(data[:origination_date]) : nil
      payoff = data[:expected_payoff_date].present? ? date_in_zone(data[:expected_payoff_date]) : nil
      { "rate_type" => "fixed", "interest_rate" => nullable_decimal(data[:interest_rate_percentage]),
        "initial_balance" => nullable_decimal(data[:origination_principal_amount]), "term_months" => origin && payoff ? (payoff - origin).to_i / 30 : nil }
    end
    # The legacy credit helper directly updates nonnil attributes; it does not
    # use Enrichable despite the provider metadata's former naming. Retain that
    # behavior explicitly instead of silently clearing nil values or adding locks.
    { "accountable_type" => kind == :credit ? "CreditCard" : "Loan", "strategy" => kind == :credit ? "update_non_null" : "update", "attributes" => attributes }
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid liabilities", cause: nil
  end

  def normalize_legacy_liabilities(raw, account:)
    data = normalized_object(raw).deep_dup
    # Legacy account snapshots contain one object per liability type; live
    # responses contain item-wide arrays. Only this explicit migration entry
    # point accepts that old shape and its monetary Float cache values.
    source = data.key?(:liabilities) ? normalized_object(data[:liabilities]) : data
    values = %i[credit mortgage student].to_h do |kind|
      rows = source[kind].nil? ? [] : source[kind].is_a?(Array) ? source[kind] : [ source[kind] ]
      converted = checked_rows(rows).map do |row|
        case kind
        when :credit
          row[:minimum_payment_amount] = legacy_decimal(row[:minimum_payment_amount])
          Array(row[:aprs]).each { |apr| apr[:apr_percentage] = legacy_decimal(apr[:apr_percentage]) }
        when :mortgage
          row[:interest_rate][:percentage] = legacy_decimal(row[:interest_rate][:percentage]) if row[:interest_rate]
        when :student
          %i[interest_rate_percentage origination_principal_amount].each { |key| row[key] = legacy_decimal(row[key]) }
        end
        row
      end
      [ kind, converted ]
    end
    normalize_liabilities({ liabilities: values }, account: account)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Plaid liabilities", cause: nil
  end

  private
    def source_security(id, securities)
      normalized_id(id)
      securities.find { |security| security[:security_id] == id && security[:ticker_symbol].present? } ||
        securities.find { |security| security[:proxy_security_id] == id }
    end

    def brokerage_cash?(security)
      security && security[:ticker_symbol] == "CUR:USD"
    end

    def security_descriptor(security)
      { ticker: normalized_id(security[:ticker_symbol]), exchange_operating_mic: security[:market_identifier_code] }.compact
    end

    def investment_account?(account)
      @region == "us" && account[:account_type] == "investment" && products_for(account).include?("investments")
    end

    def empty_investment_page
      Provider::AccountData::Page.new(records: [], complete: true, mode: "delta", warnings: [ { "code" => "investment_stream_not_applicable" } ])
    end

    def investment_scope(account, cursor, window)
      owner = Digest::SHA256.hexdigest([ @item_id, account[:external_id] ].join(":"))
      if cursor
        raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 2000
        scope = JSON.parse(Base64.strict_decode64(cursor))
        raise ArgumentError unless scope.is_a?(Hash) && scope["version"] == 1 && scope["owner"] == owner && scope["offset"].is_a?(Integer) && scope["offset"] >= 0
        raise ArgumentError unless Date.iso8601(scope.fetch("start")) <= Date.iso8601(scope.fetch("end"))
        scope
      else
        values = (window || {}).with_indifferent_access
        today = @observed_at.to_date
        start_date = values[:explicit_start] ? date_in_zone(values.fetch(:start)) : today - @history_days
        end_date = values[:end] ? [ date_in_zone(values[:end]), today ].min : today
        raise ArgumentError unless start_date <= end_date
        { "version" => 1, "owner" => owner, "offset" => 0, "start" => start_date.iso8601, "end" => end_date.iso8601 }
      end
    end

    def liability_kind(account)
      subtype = (account[:metadata] || {}).with_indifferent_access[:account_subtype]
      { [ "credit", "credit card" ] => :credit, [ "loan", "mortgage" ] => :mortgage, [ "loan", "student" ] => :student }[[ account[:account_type], subtype ]]
    end

    def nullable_decimal(value)
      value.nil? ? nil : decimal(value)
    end
end
