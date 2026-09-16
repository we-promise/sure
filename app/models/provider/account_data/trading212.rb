require "base64"
require "json"

class Provider::AccountData::Trading212 < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  CASH_TYPES = {
    "DEPOSIT" => [ "contribution", "Contribution", -1 ], "WITHDRAW" => [ "withdrawal", "Withdrawal", 1 ],
    "INTEREST" => [ "interest", "Interest", -1 ], "INTEREST_ON_FREE_CASH" => [ "interest", "Interest", -1 ],
    "FEE" => [ "fee", "Fee", 1 ]
  }.freeze
  DEFINITION = Provider::AccountData::Definition.new(
    key: "trading212", source: "trading212", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "api_key", type: "text", secret: true }, { name: "api_secret", type: "text", secret: true },
      { name: "currency", type: "string", secret: false } ]
  )

  def self.definition
    DEFINITION
  end

  def self.native_ready?
    false
  end

  def self.context_sources
    [ :trading212_instrument_catalog ]
  end

  def self.frozen_context_sources
    [ :trading212_instrument_catalog ]
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    new(client: Provider::Trading212.new(api_key: credentials.fetch(:api_key), api_secret: credentials.fetch(:api_secret),
      environment: context.fetch(:environment, "live")),
      currency: settings.with_indifferent_access[:currency].presence || context.fetch(:family_currency),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      cached_instruments: InstrumentCatalog.instruments(context.fetch(:trading212_instrument_catalog)))
  end

  def initialize(client:, currency:, timezone:, observed_at:, cached_instruments: [])
    super(client: client)
    @currency = normalized_currency(currency)
    @timezone = timezone
    @observed_at = observed_at.to_time
    @instruments = instrument_map(cached_instruments)
    @instruments_fetched = false
  end

  def list_accounts(cursor: nil)
    raise ArgumentError if cursor
    result = checked_page(client.fetch_account_summary_page)
    raise ArgumentError unless result[:next_cursor].nil? && result[:items].one?
    Provider::AccountData::Page.new(records: [ normalize_account(result[:items].first) ], complete: true, mode: "snapshot",
      evidence: { "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 account inventory", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError if cursor
    result = checked_page(client.fetch_positions_page)
    raise ArgumentError if result[:next_cursor]
    records = result[:items].filter_map { |raw| normalize_position(raw, account: account) }
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot",
      coverage: { "date" => observation_date.iso8601 }, evidence: { "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 positions", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    state = cursor ? decode_cursor(cursor) : nil
    state = { "version" => 1, "phase" => "orders", "cursor" => nil, "observed_at" => @observed_at.iso8601(9) } if state.nil? || state["phase"] == "checkpoint"
    observed_on = Time.iso8601(state.fetch("observed_at")).in_time_zone(@timezone).to_date
    catalog_evidence, warnings = state["phase"] == "dividends" ? load_instruments : [ nil, [] ]
    result = checked_page(case state["phase"]
    when "orders" then client.fetch_orders_page(cursor: state["cursor"])
    when "dividends" then client.fetch_dividends_page(cursor: state["cursor"])
    when "transactions" then client.fetch_transactions_page(cursor: state["cursor"])
    end)
    records = result[:items].filter_map do |raw|
      case state["phase"]
      when "orders" then normalize_order(raw, account: account, observed_on: observed_on)
      when "dividends" then normalize_dividend(raw, account: account, observed_on: observed_on)
      when "transactions" then normalize_cash_transaction(raw, account: account, observed_on: observed_on)
      end
    end
    next_phase = result[:next_cursor] ? state["phase"] : { "orders" => "dividends", "dividends" => "transactions" }[state["phase"]]
    next_state = state.merge("phase" => next_phase, "cursor" => result[:next_cursor]) if next_phase
    continuation = next_state ? encode_cursor(next_state) : nil
    evidence = { "phase" => state["phase"], "response" => result[:evidence] || result[:items] }
    evidence["instruments"] = catalog_evidence unless catalog_evidence.nil?
    Provider::AccountData::Page.new(records: records, complete: next_state.nil?, mode: "delta",
      next_cursor: continuation, progress_cursor: continuation,
      checkpoint_cursor: next_state ? nil : encode_cursor(state.merge("phase" => "checkpoint", "cursor" => nil)),
      coverage: { "end" => state["observed_at"], "scope" => "all_history" }, warnings: warnings, evidence: evidence)
  rescue Provider::Trading212::RateLimitError
    raise Provider::AccountData::IncompletePage, "Trading 212 history was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 activity page", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    id = normalized_id(data[:id])
    cash = normalized_object(data.fetch(:cash))
    Ingestion::Record.account(external_id: id, name: "#{I18n.t('trading212_items.defaults.name')} (#{id})",
      currency: @currency, account_type: "Investment", balance: normalized_decimal(data.fetch(:totalValue)),
      cash_balance: normalized_decimal(cash.fetch(:availableToTrade)),
      reserved_balance: cash[:reservedForOrders].nil? ? nil : normalized_decimal(cash[:reservedForOrders]),
      metadata: { institution: { name: "Trading 212", domain: "trading212.com" },
        balance_policy: { current_anchor: true, cash_balance: "cash_balance" } })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 account", cause: nil
  end

  def normalize_position(raw, account:)
    data = normalized_object(raw)
    instrument = normalized_object(data.fetch(:instrument))
    remote_ticker = normalized_id(instrument[:ticker])
    quantity = normalized_decimal(data.fetch(:quantity))
    price = normalized_decimal(data.fetch(:currentPrice))
    return nil unless quantity.positive?
    raise ArgumentError if price.negative?
    date = observation_date
    Ingestion::Record.holding(external_id: "trading212_position_#{account[:external_id]}_#{remote_ticker}_#{date.iso8601}",
      security: security_descriptor(remote_ticker, name: instrument[:name]), quantity: quantity, price: price, amount: quantity * price,
      currency: normalized_currency(instrument[:currency], fallback: account[:currency]), date: date,
      metadata: { cost_basis: data[:averagePricePaid].nil? ? nil : normalized_decimal(data[:averagePricePaid]), delete_future_holdings: false })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 position", cause: nil
  end

  def normalize_order(raw, account:, observed_on: observation_date)
    data = normalized_object(raw)
    order = normalized_object(data.fetch(:order))
    return nil unless order[:status].to_s.upcase == "FILLED"
    fill = normalized_object(data.fetch(:fill))
    instrument = normalized_object(order[:instrument] || {})
    remote_ticker = normalized_id(instrument[:ticker].presence || order[:ticker])
    quantity = normalized_decimal(fill.fetch(:quantity))
    price = normalized_decimal(fill.fetch(:price))
    return nil if quantity.zero?
    raise ArgumentError unless quantity.positive? && !price.negative? && %w[BUY SELL].include?(order[:side].to_s.upcase)
    buy = order[:side].to_s.upcase == "BUY"
    impact = normalized_object(fill[:walletImpact] || {})
    net = impact[:netValue].nil? ? order[:filledValue] : impact[:netValue]
    amount = net.nil? ? price * quantity.abs : normalized_decimal(net).abs
    security = security_descriptor(remote_ticker, name: instrument[:name])
    signed_quantity = buy ? quantity : -quantity
    label = buy ? "Buy" : "Sell"
    Ingestion::Record.activity(external_id: "trading212_order_#{normalized_id(fill[:id].presence || order[:id])}",
      activity_type: buy ? "buy" : "sell", security: security, quantity: signed_quantity, price: price,
      amount: buy ? amount : -amount, currency: normalized_currency(instrument[:currency], fallback: account[:currency]),
      date: activity_date(fill[:filledAt].presence || order[:createdAt], observed_on),
      name: "#{label} #{signed_quantity.abs} shares of #{security[:ticker]}", metadata: { investment_activity_label: label })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 order", cause: nil
  end

  def normalize_dividend(raw, account:, observed_on: observation_date)
    data = normalized_object(raw)
    reference = normalized_id(data[:reference])
    amount = normalized_decimal(data.fetch(:amount))
    return nil unless amount.positive?
    ticker = data[:ticker].presence
    security = ticker ? security_descriptor(ticker, name: @instruments[ticker]&.[](:shortName)) : nil
    attributes = { external_id: "trading212_dividend_#{reference}", activity_type: "dividend", amount: -amount.abs,
      currency: normalized_currency(account[:currency]), date: activity_date(data[:paidOn], observed_on),
      name: security ? "Dividend from #{security[:ticker]}" : "Dividend", metadata: { investment_activity_label: "Dividend",
        extra: { trading212: { reference: reference, ticker: ticker.to_s, quantity: data[:quantity],
          gross_amount_per_share: data[:grossAmountPerShare], type: data[:type] }.compact } } }
    attributes[:security] = security if security
    Ingestion::Record.activity(**attributes)
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 dividend", cause: nil
  end

  def normalize_cash_transaction(raw, account:, observed_on: observation_date)
    data = normalized_object(raw)
    type = data[:type].to_s.upcase
    classification = CASH_TYPES[type]
    return nil unless classification
    reference = normalized_id(data[:reference])
    amount = normalized_decimal(data.fetch(:amount))
    return nil if amount.zero?
    activity_type, label, sign = classification
    Ingestion::Record.activity(external_id: "trading212_transaction_#{reference}", activity_type: activity_type,
      amount: amount.abs * sign, currency: normalized_currency(account[:currency]), date: activity_date(data[:dateTime], observed_on), name: label,
      metadata: { investment_activity_label: label, extra: { trading212: { reference: reference, type: type, amount: data[:amount] } } })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Trading 212 cash activity", cause: nil
  end

  private
    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def activity_date(value, observed_on)
      value.present? ? normalized_date(value, timezone: @timezone) : observed_on
    end

    def security_descriptor(remote_ticker, name: nil)
      ticker = normalized_id(remote_ticker).split("_").first.upcase
      raise ArgumentError if ticker.blank?
      { ticker: ticker, name: name.presence || ticker, lookup: "ticker_only" }
    end

    def instrument_map(items)
      raise ArgumentError unless items.is_a?(Array)
      items.each_with_object({}) do |raw, result|
        data = normalized_object(raw)
        ticker = normalized_id(data[:ticker])
        raise ArgumentError if result.key?(ticker)
        result[ticker] = data
      end
    end

    def load_instruments
      return [ nil, [] ] if @instruments_fetched
      result = checked_page(client.fetch_instruments_page)
      raise ArgumentError if result[:next_cursor]
      @instruments = instrument_map(result[:items])
      @instruments_fetched = true
      [ result[:evidence] || result[:items], [] ]
    rescue Provider::Trading212::Error
      @instruments_fetched = true
      [ nil, [ { "code" => "instrument_catalog_unavailable_cached_metadata_used" } ] ]
    end

    def encode_cursor(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_cursor(cursor)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless state.is_a?(Hash) && state.keys.sort == %w[cursor observed_at phase version] && state["version"] == 1 &&
          %w[orders dividends transactions checkpoint].include?(state["phase"]) && state["observed_at"].is_a?(String) &&
          (state["cursor"].nil? || (state["cursor"].is_a?(String) && state["cursor"].present?))
        raise ArgumentError
      end
      Time.iso8601(state["observed_at"])
      state
    end
end
