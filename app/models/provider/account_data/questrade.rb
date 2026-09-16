require "base64"
require "digest/sha2"

class Provider::AccountData::Questrade < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include ActivityNormalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "questrade", source: "questrade", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "refresh_token", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.context_sources
    [ :credential_store, :questrade_retained_credentials ]
  end

  def self.frozen_context_sources
    [ :questrade_retained_credentials ]
  end

  def self.build(credentials:, settings:, context:)
    context.fetch(:questrade_retained_credentials)
    store = context[:credential_store]
    unless store
      raise Provider::Questrade::ConfigurationError, "Questrade requires a durable credential session store"
    end
    client = Provider::Questrade::IngestionClient.new(credential_store: store, environment: context[:environment].presence || "live")
    new(client: client, timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at))
  end

  def initialize(client:, timezone:, observed_at:)
    super(client: client)
    @timezone, @observed_at = timezone, observed_at.to_time
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    response = client.get_ingestion_accounts
    rows = checked_rows(normalized_object(response).fetch(:accounts))
    records = rows.map { |raw| normalize_account(raw) }
    raise ArgumentError unless records.map { |record| record[:external_id] }.uniq.size == records.size
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", evidence: { "response" => response })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade inventory", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    id = normalized_id(data[:number] || data[:id])
    type = data[:type].presence || "Account"
    Ingestion::Record.account(external_id: id, name: "#{type} (#{id})", currency: "CAD", account_type: type,
      sensitive_details: { account_number: id }, metadata: { balance_provided: false, account_status: data[:status],
        institution: { name: "Questrade", domain: "questrade.com" }, balance_policy: balance_policy })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade account", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    response = client.get_ingestion_balances(account_id: account[:external_id])
    values = balance_values(response, account: account)
    total = values[:total]
    if total.nil? && account[:balance]
      raise ArgumentError unless values[:currency] == account[:currency]
      total = account[:balance]
    end
    attrs = account.attributes.merge(currency: values.fetch(:currency), cash_balance: values[:cash],
      metadata: (account[:metadata] || {}).with_indifferent_access.merge(balance_provided: !total.nil?, balance_policy: balance_policy))
    attrs[:balance] = total
    evidence = { "response" => response }
    evidence["fallback_balance"] = total if values[:total].nil? && total
    evidence["fallback_cash"] = values[:cash] if normalized_object(response).fetch(:perCurrencyBalances).empty?
    Provider::AccountData::Page.new(records: [ Ingestion::Record.account(**attrs) ], complete: true, mode: "snapshot", evidence: evidence,
      warnings: values[:total].nil? ? [ { "code" => "combined_balance_unavailable" } ] : [])
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    response = client.get_ingestion_holdings(account_id: account[:external_id])
    rows = checked_rows(normalized_object(response).fetch(:positions))
    ids = rows.filter_map { |row| row[:symbolId] }.uniq
    # Symbol requests are bounded separately; the positions endpoint does not
    # report currency. Capture the exact lookup inputs with this holdings page.
    symbol_responses = ids.each_slice(100).map { |group| client.get_ingestion_symbols(ids: group) }
    currencies = symbol_responses.flat_map { |value| checked_rows(normalized_object(value).fetch(:symbols)) }
      .to_h { |row| [ normalized_id(row[:symbolId]), row[:currency] ] }
    balances = client.get_ingestion_balances(account_id: account[:external_id])
    values = balance_values(balances, account: account)
    home = Ingestion::Record.account(**account.attributes.merge(currency: values.fetch(:currency)))
    records = rows.filter_map do |row|
      row = row.deep_dup
      row[:currency] = currencies[normalized_id(row[:symbolId])] if row[:currency].blank? && row[:symbolId]
      normalize_holding(row, account: home)
    end
    records.concat(values.fetch(:non_primary_cash).map { |entry| normalize_cash_holding(entry) })
    records = unique_records(records)
    Provider::AccountData::Page.new(records: records, complete: true, mode: "delta",
      coverage: { "snapshot_date" => @observed_at.to_date.iso8601, "absence_authoritative" => false },
      evidence: { "positions" => response, "symbols" => symbol_responses, "balances" => balances })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade holdings", cause: nil
  end

  def normalize_holding(raw, account:)
    data = normalized_object(raw)
    check_owner!(data, account)
    ticker = data[:symbol].to_s.strip
    return nil if ticker.blank?
    quantity = decimal(data[:openQuantity])
    return nil if quantity.zero?
    price = decimal(data[:currentPrice])
    amount = data[:currentMarketValue].nil? ? quantity * price : decimal(data[:currentMarketValue])
    date = @observed_at.to_date
    Ingestion::Record.holding(external_id: [ "questrade", account[:external_id], data[:symbolId], date.iso8601 ].join("_"),
      date: date, quantity: quantity, price: price, amount: amount, currency: currency_for(data, account),
      security: security_descriptor(ticker, name: ticker, currency: data[:currency]),
      metadata: { delete_future_holdings: false, cost_basis: data[:averageEntryPrice].nil? ? nil : decimal(data[:averageEntryPrice]), cost_basis_source: "provider" })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade holding", cause: nil
  end

  def normalize_legacy_holding(raw, account:)
    data = normalized_object(raw).deep_dup
    %i[openQuantity currentPrice currentMarketValue averageEntryPrice].each { |key| data[key] = legacy_decimal(data[key]) if data.key?(key) }
    normalize_holding(data, account: account)
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    scope = activity_window_scope(account, cursor, window)
    from = Date.iso8601(scope.fetch("next"))
    last = Date.iso8601(scope.fetch("end"))
    to = [ from + Provider::Questrade::MAX_ACTIVITY_DAYS - 1, last ].min
    start_time = from.in_time_zone(@timezone).utc.iso8601(6)
    end_time = to.in_time_zone(@timezone).end_of_day.utc.iso8601(6)
    response = client.get_ingestion_activities(account_id: account[:external_id], start_time: start_time, end_time: end_time)
    rows = checked_rows(normalized_object(response).fetch(:activities))
    skipped = 0
    missing_prices = 0
    records = rows.flat_map do |raw|
      values = normalize_activity(raw, account: account)
      skipped += 1 if values.empty?
      if values.any? { |record| %w[buy sell].include?(record[:activity_type]) && record[:price].nil? }
        # A commission cannot be posted independently of its unresolved trade.
        # Retain the complete raw row and retry it without inventing a unit price
        # from net cash (which includes fees and may include a contract multiplier).
        missing_prices += 1
        []
      else
        values
      end
    end
    unresolved = scope.fetch("unresolved", false) || missing_prices.positive?
    complete = to == last && !unresolved
    next_cursor = activity_cursor(scope.merge("next" => (to + 1).iso8601, "unresolved" => unresolved)) if to < last
    # Continue independent later windows now, but persist the original start as
    # retry progress. A later Sync must not age unresolved rows out of its initial
    # history window or promote the completed-coverage boundary past them.
    progress_cursor = activity_cursor(scope.merge("next" => scope.fetch("start"), "unresolved" => false)) if unresolved
    warnings = []
    warnings << { "code" => "unmapped_or_nonfinancial_activities", "count" => skipped } if skipped.positive?
    warnings << { "code" => "missing_trade_price", "count" => missing_prices } if missing_prices.positive?
    warnings << { "code" => "unresolved_trade_history" } if unresolved
    Provider::AccountData::Page.new(records: unique_records(records), complete: complete, next_cursor: next_cursor,
      progress_cursor: progress_cursor, mode: "delta",
      coverage: { "start" => Date.iso8601(scope.fetch("start")).in_time_zone(@timezone).utc.iso8601(6),
        "end" => last.in_time_zone(@timezone).end_of_day.utc.iso8601(6), "absence_authoritative" => false },
      evidence: { "response" => response, "request" => { "start" => start_time, "end" => end_time } },
      warnings: warnings)
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Questrade activities", cause: nil
  end

  private
    def balance_policy
      { debt_transform: "preserve", debt_types: [], current_anchor: true }
    end

    def checked_rows(value)
      raise ArgumentError unless value.is_a?(Array) && value.size <= Provider::Questrade::IngestionClient::MAX_ROWS && value.all? { |row| row.is_a?(Hash) }
      value.map(&:with_indifferent_access)
    end

    def balance_values(response, account:)
      data = normalized_object(response)
      per = checked_rows(data.fetch(:perCurrencyBalances))
      combined = checked_rows(data.fetch(:combinedBalances))
      # Preserve the most-cash, then most-equity ranking without losing precision
      # by converting balances to Float. Missing values retain legacy zero rank.
      ranked = per.max_by { |row| [ optional_decimal(row[:cash]).abs, optional_decimal(row[:totalEquity] || row[:marketValue]).abs ] }
      currency = ranked ? normalized_currency(ranked[:currency], fallback: "CAD") : account[:currency] || "CAD"
      primary = per.find { |row| row[:currency] == currency }
      cash = if per.empty?
        optional_decimal(account[:cash_balance])
      else
        primary ? optional_decimal(primary[:cash]) : BigDecimal("0")
      end
      selected = combined.find { |row| row[:currency] == currency } || combined.first
      amount = selected && (selected[:totalEquity] || selected[:marketValue])
      non_primary = per.filter_map do |row|
        next if row[:currency].blank? || row[:currency] == currency || row[:cash].nil?
        value = decimal(row[:cash])
        next if value.abs < BigDecimal("0.01")
        { currency: normalized_currency(row[:currency]), amount: value }
      end
      { currency: currency, total: amount.nil? ? nil : decimal(amount), cash: cash, non_primary_cash: non_primary }
    end

    def normalize_cash_holding(entry)
      currency, amount, date = entry.fetch(:currency), entry.fetch(:amount), @observed_at.to_date
      Ingestion::Record.holding(external_id: "questrade_cash_#{currency.downcase}_#{date.iso8601}", currency: currency,
        date: date, quantity: amount, amount: amount, price: BigDecimal("1"),
        security: { lookup: "account_cash", currency: currency }, metadata: { delete_future_holdings: false })
    end

    def activity_cursor(scope)
      Base64.strict_encode64(JSON.generate(scope))
    end

    def activity_window_scope(account, cursor, window)
      owner = Digest::SHA256.hexdigest(account[:external_id])
      if cursor
        raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 2000
        scope = JSON.parse(Base64.strict_decode64(cursor))
        raise ArgumentError unless scope.is_a?(Hash) && scope["version"] == 1 && scope["account"] == owner && scope["timezone"] == @timezone
        raise ArgumentError unless [ true, false ].include?(scope.fetch("unresolved", false))
        from, to, following = %w[start end next].map { |key| Date.iso8601(scope.fetch(key)) }
        raise ArgumentError unless from <= following && following <= to && (following - from).to_i % Provider::Questrade::MAX_ACTIVITY_DAYS == 0
        scope
      else
        values = (window || {}).with_indifferent_access
        today = @observed_at.in_time_zone(@timezone).to_date
        start_date = if values[:explicit_start] == true
          date_in_zone(values.fetch(:start))
        elsif values[:initial] == false && values[:checkpoint_covered_through]
          date_in_zone(values[:checkpoint_covered_through]) - 30
        elsif !values.key?(:initial) && values[:start]
          date_in_zone(values[:start])
        else
          today - 1095
        end
        end_date = values[:end] ? [ date_in_zone(values[:end]), today ].min : today
        raise ArgumentError unless start_date <= end_date
        { "version" => 1, "account" => owner, "timezone" => @timezone, "start" => start_date.iso8601,
          "end" => end_date.iso8601, "next" => start_date.iso8601 }
      end
    end

    def unique_records(records)
      records.each_with_object({}) do |record, output|
        previous = output[record[:external_id]]
        raise ArgumentError if previous && previous.attributes != record.attributes
        output[record[:external_id]] = record
      end.values
    end

    def check_owner!(data, account)
      value = data[:accountNumber] || data[:accountId]
      raise ArgumentError if value && value.to_s != account[:external_id]
    end

    def optional_decimal(value)
      value.nil? ? BigDecimal("0") : decimal(value)
    end

    def legacy_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end

    def currency_for(data, account)
      value = data[:currency].is_a?(Hash) ? data.dig(:currency, :code) : data[:currency]
      normalized_currency(value, fallback: account[:currency])
    end

    def security_descriptor(ticker, name:, currency:)
      name = ticker if name.blank? || name.is_a?(Hash) || name.match?(/\A(COMMON STOCK|CRYPTOCURRENCY|ETF|MUTUAL FUND)\z/i)
      name = name.titleize if name == name.upcase && name.length > 4
      code = currency.is_a?(Hash) ? currency[:code] || currency["code"] : currency
      { ticker: ticker.strip.upcase, name: name, lookup: "ticker_only", repair_malformed_name: true,
        country_code: { "USD" => "US", "CAD" => "CA", "GBP" => "GB", "GBX" => "GB" }[code] }.compact
    end
end
