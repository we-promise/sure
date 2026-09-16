require "base64"
require "json"

# Coinbase wallets hold asset quantities; the application's account and entry
# amounts use their native fiat value. Never store a BTC quantity as USD balance.
class Provider::AccountData::Coinbase < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  DEFINITION = Provider::AccountData::Definition.new(
    key: "coinbase", source: "coinbase", credential_scope: "connection", capabilities: %w[holdings activities],
    fields: [ { name: "api_key", type: "string", secret: true }, { name: "api_secret", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [], frozen: [], inventory: "linked" }
  end

  def self.context_sources
    [ :external_accounts ]
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    new(client: Provider::Coinbase.new(api_key: credentials.fetch(:api_key), api_secret: credentials.fetch(:api_secret)),
      timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      external_accounts: context.fetch(:external_accounts, []))
  end

  def initialize(client:, timezone:, observed_at:, external_accounts: [])
    super(client: client)
    @timezone = timezone
    @observed_at = observed_at.to_time
    @linked_currencies = external_accounts.to_h do |raw|
      data = normalized_object(raw)
      [ normalized_id(data[:external_id]), data.dig(:linked_account, :currency) ]
    end
  end

  def list_accounts(cursor: nil)
    result = checked_page(client.get_accounts_page(cursor: cursor))
    Provider::AccountData::Page.new(records: result[:items].map { |raw| normalize_account(raw) },
      complete: result[:next_cursor].nil?, mode: "snapshot", next_cursor: result[:next_cursor],
      evidence: { "response" => result[:evidence] || result[:items] })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase wallet inventory", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise ArgumentError if cursor
    value, price, evidence = valuation(account)
    metadata = normalized_object(account[:metadata] || {}).deep_merge(
      balance_provided: true, valuation: { price: price.to_s("F"), observed_at: @observed_at.iso8601(9) }
    ).deep_symbolize_keys
    record = Ingestion::Record.account(**account.attributes.merge(balance: value, cash_balance: BigDecimal("0"), metadata: metadata))
    Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot", evidence: evidence)
  rescue Provider::Coinbase::RateLimitError
    raise Provider::AccountData::IncompletePage, "Coinbase valuation was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    raise ArgumentError if cursor
    metadata = normalized_object(account[:metadata] || {})
    linked_type = metadata[:linked_account_type]
    if linked_type && linked_type != "Crypto"
      return Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot")
    end
    asset = normalized_object(metadata.fetch(:asset))
    quantity = normalized_decimal(asset.fetch(:quantity))
    if quantity.zero?
      return Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot",
        coverage: { "date" => observation_date.iso8601 }, evidence: { "quantity" => quantity })
    end
    _value, price, evidence = valuation(account)
    date = observation_date
    record = Ingestion::Record.holding(external_id: "coinbase_#{account[:external_id]}_#{date.iso8601}",
      currency: normalized_currency(account[:currency]), quantity: quantity, price: price,
      amount: price.positive? ? (quantity * price).round(2) : BigDecimal("0"), date: date,
      security: security_descriptor(asset.fetch(:code), name: asset[:name]), metadata: { delete_future_holdings: false })
    Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot",
      coverage: { "date" => date.iso8601 }, evidence: evidence)
  rescue Provider::Coinbase::RateLimitError
    raise Provider::AccountData::IncompletePage, "Coinbase valuation was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase position", cause: nil
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    state = cursor ? decode_cursor(cursor, account: account) : nil
    if state.nil? || state["phase"] == "checkpoint"
      explicit_start = window && (window[:explicit_start] || window["explicit_start"])
      state = { "version" => 1, "wallet_id" => account[:external_id], "phase" => "transactions", "cursor" => nil,
        "observed_at" => @observed_at.iso8601(9), "start" => explicit_start ? window[:start] || window["start"] : nil }
    end
    result = checked_page(client.get_transactions_page(account[:external_id], cursor: state["cursor"]))
    records = result[:items].filter_map do |raw|
      record = normalize_transaction(raw, account: account)
      next unless record
      next if state["start"] && record[:date] < normalized_date(state["start"], timezone: @timezone)
      record
    end
    continuation = result[:next_cursor] && encode_cursor(state.merge("cursor" => result[:next_cursor]))
    Provider::AccountData::Page.new(records: records, complete: continuation.nil?, mode: "delta",
      next_cursor: continuation, progress_cursor: continuation,
      checkpoint_cursor: continuation ? nil : encode_cursor(state.merge("phase" => "checkpoint", "cursor" => nil)),
      coverage: { "end" => state["observed_at"], "start" => state["start"], "scope" => "wallet_history" }.compact,
      evidence: { "response" => result[:evidence] || result[:items] })
  rescue Provider::Coinbase::RateLimitError
    raise Provider::AccountData::IncompletePage, "Coinbase history was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase activity page", cause: nil
  end

  def normalize_account(raw)
    data = normalized_object(raw)
    id = normalized_id(data[:id])
    balance = normalized_object(data.fetch(:balance))
    currency_data = normalized_object(data[:currency] || {})
    code = asset_code(balance[:currency].presence || currency_data[:code])
    quantity = normalized_decimal(balance.fetch(:amount))
    native = normalized_object(data[:native_balance] || {})
    currency = normalized_currency(native[:currency].presence || @linked_currencies[id].presence || "USD")
    value = native[:amount].nil? ? nil : normalized_decimal(native[:amount])
    value ||= BigDecimal("0") if quantity.zero?
    Ingestion::Record.account(external_id: id, name: data[:name].presence || code, currency: currency,
      account_type: "Crypto", balance: value, cash_balance: value.nil? ? nil : BigDecimal("0"),
      metadata: { institution: { name: "Coinbase", domain: "coinbase.com" },
        wallet_type: data[:type], wallet_status: data[:status].presence || "active",
        asset: { code: code, name: currency_data[:name].presence || code, type: currency_data[:type], quantity: quantity.to_s("F") },
        asset_observed_at: @observed_at.iso8601(9),
        valuation: { native_amount: native[:amount].nil? ? nil : normalized_decimal(native[:amount]).to_s("F"), price: nil, observed_at: nil },
        balance_provided: !value.nil?, balance_policy: { cash_balance: "cash_balance" } })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase wallet", cause: nil
  end

  def normalize_transaction(raw, account:)
    data = normalized_object(raw)
    status = normalized_id(data[:status])
    type = normalized_id(data[:type])
    return nil unless status == "completed" && %w[buy sell].include?(type)
    amount_data = normalized_object(data.fetch(:amount))
    native_data = normalized_object(data.fetch(:native_amount))
    quantity = normalized_decimal(amount_data.fetch(:amount)).abs
    raise ArgumentError unless quantity.positive?
    amount = normalized_decimal(native_data.fetch(:amount)).abs
    details = normalized_object(data[type] || {})
    if details[:subtotal]
      subtotal = normalized_decimal(normalized_object(details[:subtotal]).fetch(:amount))
      amount = subtotal if subtotal.positive?
    end
    buy = type == "buy"
    security = security_descriptor(asset_code(amount_data[:currency]))
    label = buy ? "Buy" : "Sell"
    native_id = "coinbase_txn_#{normalized_id(data[:id])}"
    legacy_id = details[:id]
    unless legacy_id.nil? || (legacy_id.is_a?(String) && legacy_id.present? && legacy_id.bytesize <= 512)
      raise ArgumentError
    end
    Ingestion::Record.activity(external_id: native_id, activity_type: type,
      name: "#{label} #{quantity.round(8)} #{security[:ticker]}",
      date: normalized_date(data.fetch(:created_at), timezone: @timezone),
      currency: normalized_currency(native_data[:currency].presence || account[:currency]),
      quantity: buy ? quantity : -quantity, price: (amount / quantity).round(8), amount: buy ? -amount : amount,
      security: security, metadata: { investment_activity_label: label, update_policy: "insert_only",
        repair_activity_label: true, notes: transaction_notes(data, details), legacy_buy_sell_id: legacy_id,
        coinbase_transaction_id: native_id })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase trade", cause: nil
  end

  # Cached deprecated endpoint payloads remain a distinct migration projection.
  # Fetching both endpoint families automatically would duplicate the same trade.
  def normalize_legacy_transaction(raw, type:, account:)
    raise ArgumentError unless %w[buy sell].include?(type)
    data = normalized_object(raw)
    return nil unless normalized_id(data[:status]) == "completed"
    amount_data = normalized_object(data.fetch(:amount))
    total = normalized_object(data.fetch(:total))
    quantity = normalized_decimal(amount_data.fetch(:amount))
    price = normalized_decimal(normalized_object(data.fetch(:unit_price)).fetch(:amount))
    raise ArgumentError unless quantity.positive? && !price.negative?
    value = normalized_decimal(total.fetch(:amount))
    security = security_descriptor(asset_code(amount_data[:currency]))
    buy = type == "buy"
    label = buy ? "Buy" : "Sell"
    Ingestion::Record.activity(external_id: "coinbase_#{type}_#{normalized_id(data[:id])}", activity_type: type,
      name: "#{label} #{security[:ticker]}", date: normalized_date(data.fetch(:created_at), timezone: @timezone),
      currency: normalized_currency(total[:currency].presence || account[:currency]),
      quantity: buy ? quantity : -quantity, price: price, amount: buy ? -value : value, security: security,
      metadata: { investment_activity_label: label, update_policy: "insert_only", repair_activity_label: true })
  rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Coinbase legacy trade", cause: nil
  end

  private
    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def asset_code(value)
      unless value.is_a?(String) && value.match?(/\A(?:[A-Za-z][A-Za-z0-9]*:)?[A-Za-z0-9][A-Za-z0-9._-]*\z/)
        raise ArgumentError
      end
      value.upcase
    end

    def security_descriptor(code, name: nil)
      code = asset_code(code)
      { ticker: code.include?(":") ? code : "CRYPTO:#{code}", name: name.presence || code,
        fallback_offline: true, fallback_lookup: "ticker_only", fallback_exchange_operating_mic: "XCBS" }
    end

    def valuation(account)
      metadata = normalized_object(account[:metadata] || {})
      if metadata[:balance_snapshot_current] == false && metadata[:asset_observed_at] != @observed_at.iso8601(9)
        raise Provider::AccountData::IncompletePage, "The current inventory did not include this wallet's valuation"
      end
      asset = normalized_object(metadata.fetch(:asset))
      quantity = normalized_decimal(asset.fetch(:quantity))
      native = metadata.dig(:valuation, :native_amount)
      if metadata.dig(:valuation, :observed_at) == @observed_at.iso8601(9) && metadata.dig(:valuation, :price)
        price = normalized_decimal(metadata.dig(:valuation, :price))
        raise ArgumentError if price.negative?
        return [ native.nil? ? (quantity * price).round(2) : normalized_decimal(native), price,
          { "valuation" => "captured_balance_price", "quantity" => quantity, "price" => price } ]
      end
      unless native.nil?
        amount = normalized_decimal(native)
        if quantity.positive?
          price = (amount / quantity).round(8)
          raise ArgumentError if price.negative?
          return [ amount, price, { "valuation" => "inventory_native_balance", "quantity" => quantity, "native_amount" => amount } ]
        end
        return [ amount, BigDecimal("0"), { "valuation" => "inventory_native_balance", "quantity" => quantity, "native_amount" => amount } ] if quantity.zero?
      end
      return [ BigDecimal("0"), BigDecimal("0"), { "quantity" => quantity } ] if quantity.zero?
      code = asset_code(asset.fetch(:code))
      currency = normalized_currency(account[:currency])
      result = checked_page(client.get_spot_price_page("#{code}-#{currency}"))
      raise ArgumentError unless result[:items].one? && result[:next_cursor].nil?
      data = normalized_object(result[:items].first)
      raise ArgumentError if data[:currency] && normalized_currency(data[:currency]) != currency
      price = normalized_decimal(data.fetch(:amount))
      raise ArgumentError if price.negative?
      [ native.nil? ? (quantity * price).round(2) : normalized_decimal(native), price,
        { "valuation" => "spot_price", "quantity" => quantity, "response" => result[:evidence] || result[:items] } ]
    rescue Provider::Coinbase::ApiError
      # The old processor also tried cached Security prices and today's holdings.
      # Those require an explicit context snapshot before native activation.
      raise Provider::AccountData::IncompletePage, "Coinbase valuation needs an available price", cause: nil
    end

    def transaction_notes(data, details)
      summary = normalized_object(data[:details] || {})
      parts = [ data[:description], summary[:title], summary[:subtitle] ].select(&:present?)
      raise ArgumentError unless parts.all? { |part| part.is_a?(String) }
      if details[:payment_method_name].present?
        raise ArgumentError unless details[:payment_method_name].is_a?(String)
        parts << I18n.t("coinbase.processor.paid_via", method: details[:payment_method_name])
      end
      parts.join(" - ").presence
    end

    def encode_cursor(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_cursor(cursor, account:)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      unless state.is_a?(Hash) && state.keys.sort == %w[cursor observed_at phase start version wallet_id] &&
          state["version"] == 1 && state["wallet_id"] == account[:external_id] &&
          %w[transactions checkpoint].include?(state["phase"]) && state["observed_at"].is_a?(String) &&
          (state["cursor"].nil? || (state["cursor"].is_a?(String) && state["cursor"].present?)) &&
          (state["start"].nil? || state["start"].is_a?(String))
        raise ArgumentError
      end
      Time.iso8601(state["observed_at"])
      normalized_date(state["start"], timezone: @timezone) if state["start"]
      state
    end
end
