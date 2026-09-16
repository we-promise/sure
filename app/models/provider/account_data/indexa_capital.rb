class Provider::AccountData::IndexaCapital < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include ActivityNormalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "indexa_capital", source: "indexa_capital", credential_scope: "connection", capabilities: [ "holdings" ],
    fields: %w[api_token username document password].map { |name| { name: name, type: "text", secret: true } }
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [ "currency" ], frozen: %w[cash_balance current_balance], inventory: "linked" }
  end

  def self.context_sources
    [ :external_accounts, :fallback_credentials ]
  end

  def self.build(credentials:, settings:, context:)
    values = credentials.with_indifferent_access
    token = values[:api_token].presence || context.fetch(:fallback_credentials, {}).with_indifferent_access[:api_token].presence
    client = if token
      Provider::IndexaCapital.new(api_token: token)
    else
      Provider::IndexaCapital.new(username: values[:username], document: values[:document], password: values[:password])
    end
    new(client: client, timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at), external_accounts: context.fetch(:external_accounts))
  end

  def initialize(client:, timezone:, observed_at:, external_accounts: [])
    super(client: client)
    @timezone, @observed_at = timezone, observed_at.to_time
    @external_accounts = external_accounts.map { |account| account.with_indifferent_access.deep_dup }
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    response = client.get_ingestion_accounts
    data = normalized_object(response)
    rows = checked_rows(data.fetch(:accounts))
    Provider::AccountData::Page.new(records: rows.map { |raw| normalize_account(raw) }, complete: true, mode: "snapshot", evidence: { "response" => response })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital account inventory", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    id = normalized_id(data[:account_number])
    type = data[:type]
    label = case type
    when "mutual" then "Mutual Fund"
    when "pension", "epsv" then "Pension Plan"
    else type&.titleize || "Account"
    end
    Ingestion::Record.account(external_id: id, name: "Indexa Capital #{label} (#{id})", currency: "EUR", account_type: type,
      metadata: { balance_provided: false, account_status: data[:status], institution: { name: "Indexa Capital", domain: "indexacapital.com" },
        balance_policy: { debt_transform: "preserve", debt_types: [], current_anchor: true } })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital account", cause: nil
  end

  def normalize_legacy_account(raw)
    data = normalized_object(raw)
    record = normalize_account(data)
    attrs = record.attributes
    attrs = attrs.merge(name: data[:name]) if data[:name].present?
    if data.key?(:current_balance) && !data[:current_balance].nil?
      attrs = attrs.merge(balance: decimal(legacy_float_decimal(data[:current_balance])), cash_balance: BigDecimal("0"),
        metadata: attrs[:metadata].merge(balance_provided: true))
    end
    Ingestion::Record.account(**attrs)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Indexa Capital account", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    stored = @external_accounts.find { |value| value[:external_id] == account[:external_id] } || {}
    cash = stored[:cash_balance].nil? ? BigDecimal("0") : decimal(stored[:cash_balance])
    response = client.get_ingestion_performance(account_number: account[:external_id])
    portfolios = checked_rows(normalized_object(response).fetch(:portfolios))
    # An explicitly empty performance history is the legacy provider's zero
    # balance. Missing/invalid history is an error, not an empty collection.
    latest = portfolios.max_by { |row| date_in_zone(row[:date]) }
    total = latest ? decimal(latest.fetch(:total_amount)) : BigDecimal("0")
    balance_page(account, total, cash, evidence: { "response" => response })
  rescue Provider::IndexaCapital::Error => error
    raise if error.is_a?(Provider::IndexaCapital::AuthenticationError)
    if stored && !stored[:current_balance].nil?
      total = decimal(stored[:current_balance])
      evidence = { "fallback_balance" => total, "fallback_cash_balance" => cash }
    else
      holdings = fetch_holdings(account: account)
      total = holdings.records.sum(BigDecimal("0")) { |holding| holding[:amount] } + cash
      evidence = { "holdings" => holdings.evidence, "fallback_cash_balance" => cash }
    end
    balance_page(account, total, cash, evidence: evidence,
      warnings: [ { "code" => "performance_balance_unavailable", "error_type" => error.error_type.to_s } ])
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError unless cursor.nil?
    fiscal = client.get_ingestion_fiscal_results(account_number: account[:external_id])
    rows = fiscal_rows(fiscal)
    evidence = { "fiscal_results" => fiscal }
    if rows.empty?
      portfolio = client.get_ingestion_portfolio(account_number: account[:external_id])
      evidence["portfolio"] = portfolio
      rows = portfolio_rows(portfolio)
    end
    # The legacy importer intentionally keeps the last row for each instrument;
    # summing tax lots or historic snapshots would overstate the portfolio.
    selected = rows.each_with_object({}) { |row, result| result[instrument_key(row)] = row }
    Provider::AccountData::Page.new(records: selected.values.map { |row| normalize_holding(row, account: account) }, complete: true, mode: "delta",
      coverage: { "snapshot_date" => @observed_at.to_date.iso8601, "absence_authoritative" => false }, evidence: evidence)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital holdings response", cause: nil
  end

  def normalize_holding(raw, account:)
    data = normalized_object(raw)
    if data[:account].present? && data[:account] != account[:external_id]
      raise ArgumentError, "Holding belongs to another account"
    end
    key = instrument_key(data)
    quantity = decimal(data[:titles] || data[:quantity] || data[:units])
    price = decimal(data[:price])
    amount = data[:amount].nil? ? quantity * price : decimal(data[:amount])
    date = @observed_at.to_date
    Ingestion::Record.holding(external_id: "indexa_capital_#{key}_#{date.iso8601}", currency: "EUR", date: date,
      quantity: quantity, price: price, amount: amount, security: security_descriptor(key, data, holding: true),
      metadata: { holding_identity: "security_date_currency", delete_future_holdings: false,
        cost_basis: data[:cost_price].nil? ? nil : decimal(data[:cost_price]), cost_basis_source: "provider" })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Indexa Capital holding", cause: nil
  end

  def normalize_legacy_holding(raw, account:)
    data = normalized_object(raw).deep_dup
    %i[amount titles quantity units price cost_price cost_amount].each { |field| data[field] = legacy_float_decimal(data[field]) if data.key?(field) }
    normalize_holding(data, account: account)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Indexa Capital holding", cause: nil
  end

  private
    def checked_rows(value)
      raise ArgumentError unless value.is_a?(Array) && value.all? { |row| row.is_a?(Hash) }
      value.map(&:with_indifferent_access)
    end

    def fiscal_rows(response)
      return checked_rows(response) if response.is_a?(Array)
      data = normalized_object(response)
      if data[:total_fiscal_results].present?
        checked_rows(data[:total_fiscal_results])
      else
        key = %i[fiscal_results results positions data total_fiscal_results].find { |candidate| data.key?(candidate) }
        raise ArgumentError unless key
        checked_rows(data.fetch(key))
      end
    end

    def portfolio_rows(response)
      data = normalized_object(response)
      checked_rows(data.fetch(:instrument_accounts)).flat_map do |account|
        checked_rows(account.fetch(:positions)).map do |row|
          row = row.deep_dup
          if row[:cost_price].blank? && !row[:cost_amount].nil?
            quantity = decimal(row[:titles])
            row[:cost_price] = decimal(row[:cost_amount]) / quantity unless quantity.zero?
          end
          row
        end
      end
    end

    def instrument_key(data)
      instrument = data[:instrument]
      key = if instrument.is_a?(Hash)
        instrument[:identifier] || instrument[:isin_code] || instrument[:isin]
      else
        data[:identifier] || data[:isin_code] || data[:isin] || data[:symbol] || data[:ticker]
      end
      normalized_id(key).strip.upcase
    end

    def balance_page(account, balance, cash, evidence:, warnings: [])
      record = Ingestion::Record.account(**account.attributes.merge(balance: balance, cash_balance: cash, currency: "EUR",
        metadata: (account[:metadata] || {}).with_indifferent_access.merge(balance_provided: true)))
      Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot", evidence: evidence, warnings: warnings)
    end

    def security_descriptor(ticker, data, holding: false)
      instrument = data[:instrument]
      name = holding && instrument.is_a?(Hash) ? instrument[:name].presence || instrument[:description].presence : nil
      name ||= data[:name].presence || data[:description].presence
      name = ticker if name.blank? || name.is_a?(Hash) || (!holding && name.match?(/\A(COMMON STOCK|CRYPTOCURRENCY|ETF|MUTUAL FUND)\z/i))
      name = name.titleize if !holding && name == name.upcase && name.length > 4
      currency = data[:currency].is_a?(Hash) ? data.dig(:currency, :code) : data[:currency]
      country = { "USD" => "US", "CAD" => "CA", "GBP" => "GB", "GBX" => "GB" }[currency]
      exchange = data[:exchange].is_a?(Hash) ? data.dig(:exchange, :mic_code) || data.dig(:exchange, :id) : nil
      { ticker: ticker.strip.upcase, name: name, lookup: "ticker_only", exchange_mic: exchange,
        country_code: country, repair_malformed_name: true }.compact
    end

    def legacy_float_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end
end
