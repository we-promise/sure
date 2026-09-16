require "base64"
require "json"

class Provider::AccountData::Kraken < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization

  class MissingValuation < Provider::AccountData::InvalidResponse; end

  STABLECOINS = %w[USDT USDC DAI PYUSD USDP TUSD USDG].freeze
  FIAT_CURRENCIES = %w[USD EUR GBP CAD AUD CHF JPY AED].freeze
  LEDGER_TYPES = { "deposit" => [ "Contribution", "Deposit", -1 ], "withdrawal" => [ "Withdrawal", "Withdrawal", 1 ],
    "staking" => [ "Dividend", "Staking reward", -1 ], "earn" => [ "Interest", "Earn reward", -1 ],
    "fee" => [ "Fee", "Fee", 1 ] }.freeze
  PAGE_SIZE = 50
  HISTORY_PAGES_PER_RUN = 20
  DEFINITION = Provider::AccountData::Definition.new(
    key: "kraken", source: "kraken", credential_scope: "connection", capabilities: %w[transactions holdings activities],
    fields: [ { name: "api_key", type: "text", secret: true }, { name: "api_secret", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [], frozen: [ "name" ], inventory: "linked" }
  end

  def self.context_sources
    %i[connection_details external_accounts nonce_generator exchange_rate_resolver]
  end

  def self.build(credentials:, settings:, context:)
    # Runtime supplies trusted dependencies. In particular, never silently use a
    # process-local nonce when another legacy/native writer may share this key.
    nonce = context.fetch(:nonce_generator)
    rates = context.fetch(:exchange_rate_resolver)
    raise ArgumentError unless nonce.respond_to?(:call) && rates.respond_to?(:call)
    existing = context.fetch(:external_accounts).find { |record| record.fetch(:external_id) == "combined" }
    new(client: Provider::Kraken.new(api_key: credentials.fetch("api_key"), api_secret: credentials.fetch("api_secret"), nonce_generator: nonce),
      currency: context.fetch(:family_currency), timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      exchange_rate_resolver: rates, connection_id: context.fetch(:connection_details).fetch(:id), name: existing&.fetch(:name) || "Kraken")
  end

  # Native readiness remains false until shared nonce/FX dependencies, initial
  # history translation, trade fee preservation and lifecycle parity are verified.
  def initialize(client:, currency:, timezone:, observed_at:, exchange_rate_resolver:, connection_id:, name: "Kraken")
    super(client: client)
    @currency = normalized_id(currency).upcase
    Money::Currency.new(@currency)
    raise ArgumentError unless exchange_rate_resolver.respond_to?(:call) && (observed_at.is_a?(Time) || observed_at.is_a?(DateTime))
    @timezone = timezone
    @observed_at = observed_at.to_time
    @rate_resolver = exchange_rate_resolver
    @name = name
    @connection_id = normalized_id(connection_id)
    @rates = {}
    @history_requests = Hash.new(0)
  end

  def list_accounts(cursor: nil)
    reject_cursor!(cursor)
    response = client.get_api_key_info_snapshot
    result(response)
    Provider::AccountData::Page.new(records: [ account_record ], complete: true, mode: "snapshot",
      evidence: { "api_key_info" => response }, coverage: { "resource" => "account", "topology" => "combined_default_wallet" })
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    reject_cursor!(cursor)
    combined!(account)
    evidence, warnings = {}, []
    balances_response = client.get_extended_balance_snapshot
    assets_response, pairs_response = catalogs
    evidence.merge!("balances" => balances_response, "asset_metadata" => assets_response, "pair_metadata" => pairs_response)
    raw_assets = parse_assets(result(balances_response), asset_metadata: result(assets_response))
    tickers_response = raw_assets.any? { |asset| !fiat_or_stable?(asset.fetch("price_symbol")) } ? client.get_ticker_snapshot : nil
    evidence["tickers"] = tickers_response if tickers_response
    tickers = tickers_response ? result(tickers_response) : {}
    assets = raw_assets.map do |asset|
      price, status = asset_price(asset.fetch("price_symbol"), tickers: tickers, pairs: result(pairs_response))
      warnings << warning("missing_asset_price") unless price
      asset.merge("price_usd" => price&.to_s("F"), "price_status" => status,
        "amount_usd" => price ? (decimal(asset.fetch("balance")) * price).round(2).to_s("F") : nil)
    end
    valuation = { "schema_version" => 1, "observed_at" => observed_at.iso8601(9), "assets" => assets,
      "asset_metadata" => result(assets_response), "pair_metadata" => result(pairs_response) }
    record = begin
      raise MissingValuation if warnings.any?
      normalize_balance(valuation)
    rescue MissingValuation
      warnings << warning("missing_balance_valuation")
      account_record(sensitive_details: { kraken_valuation: valuation })
    end
    Provider::AccountData::Page.new(records: [ record ], complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      evidence: evidence.merge("valuation" => valuation, "exchange_rates" => rate_evidence), coverage: { "resource" => "balance" })
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Kraken balance observation", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    reject_cursor!(cursor)
    combined!(account)
    linked_type = (account[:metadata] || {}).with_indifferent_access[:linked_account_type]
    unless linked_type == "Crypto"
      return Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot",
        coverage: { "resource" => "holding", "supported" => false, "absence_authoritative" => false })
    end
    valuation = valuation_for(account)
    warnings = []
    records = valuation.fetch("assets").filter_map do |raw|
      normalize_holding(raw, observed_on: observation_date)
    rescue MissingValuation
      warnings << warning("missing_holding_valuation")
      nil
    rescue Provider::AccountData::InvalidResponse
      warnings << warning("invalid_holding")
      nil
    end
    Provider::AccountData::Page.new(records: records, complete: warnings.empty?, mode: "snapshot", warnings: warnings,
      coverage: { "resource" => "holding", "observed_date" => observation_date.iso8601,
        "absence_authoritative" => false, "delete_future_holdings" => false },
      evidence: { "valuation" => valuation, "exchange_rates" => rate_evidence })
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    history_page("ledgers", account: account, cursor: cursor, window: window)
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    history_page("trades", account: account, cursor: cursor, window: window)
  end

  def parse_assets(balances, asset_metadata:)
    normalizer = Assets.new(asset_metadata)
    normalized_object(balances).filter_map do |raw_asset, values|
      data = normalized_object(values)
      balance = decimal(data.fetch(:balance, "0"))
      credit = decimal(data.fetch(:credit, "0"))
      credit_used = decimal(data.fetch(:credit_used, "0"))
      held = decimal(data.fetch(:hold_trade, "0"))
      next if balance.zero? && held.zero?
      normalizer.normalize(raw_asset).merge("balance" => balance.to_s("F"),
        "available" => (balance + credit - credit_used - held).to_s("F"), "hold_trade" => held.to_s("F"), "source" => "spot")
    end
  end

  def normalize_balance(valuation)
    total_usd = valuation.fetch("assets").sum(BigDecimal("0")) { |asset| decimal(asset.fetch("amount_usd")) }.round(2)
    amount, stale, rate_date = convert_usd(total_usd, observation_date)
    account_record(balance: amount, cash_balance: BigDecimal("0"),
      metadata: { balance_provided: true, extra: stale_extra(stale, rate_date, observation_date) },
      sensitive_details: { kraken_valuation: valuation })
  end

  def normalize_holding(raw, observed_on: observation_date)
    data = normalized_object(raw)
    symbol = normalized_id(data.fetch(:symbol))
    quantity = decimal(data.fetch(:balance))
    return nil if quantity.zero?
    raise MissingValuation, "Missing Kraken holding price" if data[:price_usd].blank?
    price_usd = decimal(data[:price_usd])
    raise ArgumentError unless price_usd.positive?
    amount, amount_stale, rate_date = convert_usd(quantity * price_usd, observed_on)
    price, price_stale, = convert_usd(price_usd, observed_on)
    Ingestion::Record.holding(external_id: "kraken_#{symbol}_#{data[:source].presence || 'spot'}_#{observed_on}",
      quantity: quantity, price: price, amount: amount, currency: currency, date: observed_on, security: security(symbol),
      metadata: { cost_basis: nil, delete_future_holdings: false,
        extra: stale_extra(amount_stale || price_stale, rate_date, observed_on) })
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Kraken holding", cause: nil
  end

  def normalize_trade(id, raw, asset_metadata:, pair_metadata:)
    data = normalized_object(raw)
    type = data[:type].to_s.downcase
    return nil unless %w[buy sell].include?(type)
    quantity = decimal(data.fetch(:vol))
    return nil if quantity.zero?
    raise ArgumentError unless quantity.positive?
    base, quote = Assets.new(asset_metadata).pair_symbols(normalized_id(data.fetch(:pair)), pairs: pair_metadata)
    price = decimal(data.fetch(:price))
    cost = data[:cost].present? ? decimal(data[:cost]) : (quantity * price).round(8)
    fee = data[:fee].present? ? decimal(data[:fee]) : BigDecimal("0")
    label = type == "buy" ? "Buy" : "Sell"
    # Kraken historically stores the quoted denomination and opposite cash sign
    # to several brokerage adapters. Keep both unchanged, including crypto quotes.
    Ingestion::Record.activity(external_id: "kraken_trade_#{normalized_id(id)}", activity_type: type,
      amount: type == "buy" ? -cost : cost, quantity: type == "buy" ? quantity : -quantity,
      price: price, currency: normalized_id(quote), date: timestamp_date(data.fetch(:time)),
      name: "#{label} #{quantity.round(8)} #{base}", security: security(base),
      metadata: { investment_activity_label: label, notes: data[:ordertxid].presence, fee: fee, update_policy: "insert_only" })
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Kraken trade", cause: nil
  end

  def normalize_ledger(id, raw, valuation:)
    data = normalized_object(raw)
    type, subtype = data[:type].to_s.downcase, data[:subtype].to_s.downcase
    classification = LEDGER_TYPES[type]
    return nil unless classification
    return nil if type == "earn" && %w[allocation deallocation].include?(subtype)
    impact = (decimal(data.fetch(:amount)) - decimal(data.fetch(:fee, "0"))).abs
    return nil if impact.zero?
    raw_asset = normalized_id(data.fetch(:asset))
    symbol = Assets.new(valuation.fetch("asset_metadata")).normalize(raw_asset).fetch("symbol")
    date = timestamp_date(data.fetch(:time))
    amount, stale = ledger_amount(impact, symbol, date, valuation.fetch("assets"))
    label, prefix, sign = classification
    quantity = impact.round(8).to_s("F").sub(/\.?0+\z/, "")
    extra = { "kraken" => { "ledger_id" => id, "refid" => data[:refid], "raw_asset" => raw_asset,
      "raw_amount" => data[:amount], "fee_native" => data[:fee], "type" => data[:type], "subtype" => data[:subtype] } }
    extra["kraken"]["price_missing"] = true if stale
    Ingestion::Record.transaction(external_id: "kraken_ledger_#{normalized_id(id)}", name: "#{prefix} #{quantity} #{symbol}",
      amount: sign * amount.abs, currency: currency, date: date, pending: false,
      metadata: { pending_provided: false, kind: %w[deposit withdrawal].include?(type) ? "funds_movement" : "standard",
        investment_activity_label: label, extra: extra, update_policy: "insert_only" })
  rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
    raise Provider::AccountData::InvalidResponse, "Invalid Kraken ledger entry", cause: nil
  end

  def normalize_legacy_trade(id, raw, **catalogs)
    normalize_trade(id, legacy_decimals(raw, %i[vol price cost fee]), **catalogs)
  end

  def normalize_legacy_ledger(id, raw, valuation:)
    normalize_ledger(id, legacy_decimals(raw, %i[amount fee]), valuation: valuation)
  end

  private
    attr_reader :currency, :timezone, :observed_at

    def observation_date
      observed_at.in_time_zone(timezone).to_date
    end

    def account_record(metadata: {}, **attributes)
      Ingestion::Record.account(**{
        external_id: "combined", name: @name, currency: currency, account_type: "combined",
        metadata: { balance_provided: false, institution: { name: "Kraken", domain: "kraken.com", url: "https://www.kraken.com" },
          balance_policy: { cash_balance: "record", debt_transform: "preserve" } }.merge(metadata)
      }.merge(attributes))
    end

    def combined!(account)
      raise Provider::AccountData::InvalidResponse, "Unexpected Kraken account identity" unless account[:external_id] == "combined"
    end

    def reject_cursor!(cursor)
      raise Provider::AccountData::InvalidResponse, "Kraken snapshot has no continuation" unless cursor.nil?
    end

    def result(response)
      data = normalized_object(response)
      raise ArgumentError unless data[:error].is_a?(Array) && data[:error].all? { |error| error.is_a?(String) && error.blank? }
      normalized_object(data.fetch(:result)).to_h.deep_stringify_keys
    end

    def catalogs
      @catalogs ||= [ client.get_asset_info_snapshot, client.get_asset_pairs_snapshot ].tap { |responses| responses.each { |response| result(response) } }
    end

    def fiat_or_stable?(symbol)
      FIAT_CURRENCIES.include?(symbol) || STABLECOINS.include?(symbol)
    end

    def asset_price(symbol, tickers:, pairs:)
      return [ BigDecimal("1"), "exact" ] if symbol == "USD" || STABLECOINS.include?(symbol)
      if FIAT_CURRENCIES.include?(symbol)
        rate = rate_for(symbol, "USD", observation_date)
        return rate ? [ rate.fetch("rate"), rate.fetch("date") == observation_date.iso8601 ? "exact" : "stale" ] : [ nil, "missing" ]
      end
      kraken_symbol = symbol == "BTC" ? "XBT" : symbol
      [ "#{kraken_symbol}USD", "#{symbol}USD", "X#{kraken_symbol}ZUSD", "#{kraken_symbol}USDT", "#{symbol}USDT" ].uniq.each do |candidate|
        pair = pairs.key?(candidate) ? candidate : pairs.find { |_, value| value.is_a?(Hash) && value["altname"] == candidate }&.first
        data = tickers[candidate] || (pair && tickers[pair])
        next unless data.is_a?(Hash) && data.dig("c", 0).present?
        price = decimal(data.dig("c", 0))
        return [ price, "exact" ] if price.positive?
      end
      [ nil, "missing" ]
    end

    def valuation_for(account)
      snapshot = (account[:sensitive_details] || {}).with_indifferent_access[:kraken_valuation]
      snapshot = normalized_object(snapshot).to_h.deep_stringify_keys
      unless snapshot["schema_version"] == 1 && Time.iso8601(snapshot.fetch("observed_at")) == observed_at && snapshot["assets"].is_a?(Array)
        raise Provider::AccountData::IncompletePage, "A current captured Kraken valuation is required"
      end
      snapshot
    rescue ArgumentError, KeyError, TypeError
      raise Provider::AccountData::IncompletePage, "A captured Kraken valuation is required", cause: nil
    end

    def rate_for(from, to, date)
      key = [ from, to, date.iso8601 ].freeze
      return @rates[key] if @rates.key?(key)
      value = @rate_resolver.call(from: from, to: to, date: date)
      return @rates[key] = nil if value.nil?
      value = normalized_object(value)
      rate = decimal(value.fetch(:rate))
      date_used = Date.iso8601(value.fetch(:date))
      raise ArgumentError unless rate.positive?
      @rates[key] = { "rate" => rate, "date" => date_used.iso8601 }
    end

    def rate_evidence
      @rates.map do |(from, to, date), result|
        { "from" => from, "to" => to, "requested_date" => date, "result" => result }
      end
    end

    def convert_usd(amount, date)
      return [ amount, false, nil ] if currency == "USD"
      rate = rate_for("USD", currency, date)
      raise MissingValuation, "Missing Kraken currency conversion" unless rate
      stale = rate.fetch("date") != date.iso8601
      [ amount * rate.fetch("rate"), stale, stale ? rate.fetch("date") : nil ]
    end

    def ledger_amount(impact, symbol, date, assets)
      return [ impact, false ] if symbol == currency
      if FIAT_CURRENCIES.include?(symbol)
        amount = if symbol == "USD"
          impact
        else
          rate = rate_for(symbol, "USD", date)
          raise MissingValuation, "Missing Kraken fiat conversion" unless rate
          impact * rate.fetch("rate")
        end
        converted, stale, = convert_usd(amount, date)
        return [ converted, stale ]
      end
      asset = assets.find { |value| value.fetch("symbol").upcase == symbol.upcase }
      raise MissingValuation, "Missing Kraken ledger price" unless asset && asset["price_usd"].present?
      converted, stale, = convert_usd(impact * decimal(asset.fetch("price_usd")), date)
      [ converted, stale ]
    end

    def stale_extra(stale, rate_date, target_date)
      { kraken: stale ? { stale_rate: true, rate_date_used: rate_date, rate_target_date: target_date.iso8601 } : { stale_rate: false } }
    end

    def security(symbol)
      { ticker: symbol.include?(":") ? symbol : "CRYPTO:#{symbol}", name: symbol,
        fallback_offline: true, fallback_exchange_operating_mic: "XKRA" }
    end

    def timestamp_date(value)
      number = value.is_a?(Float) && value.finite? ? BigDecimal(value.to_s) : decimal(value)
      Time.at(number.to_r).in_time_zone(timezone).to_date
    end

    def legacy_decimals(raw, fields)
      data = normalized_object(raw).deep_dup
      fields.each { |key| data[key] = BigDecimal(data[key].to_s) if data[key].is_a?(Float) && data[key].finite? }
      data
    end

    def history_page(resource, account:, cursor:, window:)
      combined!(account)
      if @history_requests[resource] >= HISTORY_PAGES_PER_RUN
        raise Provider::AccountData::IncompletePage, "Kraken history request budget exhausted; saved progress can resume"
      end
      state = history_state(resource, cursor, window)
      @history_requests[resource] += 1
      response = if resource == "trades"
        client.get_trades_history_page(start: state["start"], end_at: state.fetch("end"), offset: state.fetch("offset"))
      else
        client.get_ledgers_page(start: state["start"], end_at: state.fetch("end"), offset: state.fetch("offset"))
      end
      data = result(response)
      rows = data.fetch(resource == "trades" ? "trades" : "ledger")
      count = data.fetch("count")
      raise ArgumentError unless rows.is_a?(Hash) && rows.size <= PAGE_SIZE && count.is_a?(Integer) && count >= 0
      warnings = []
      warnings << warning("history_count_changed") if state["count"] && state["count"] != count
      warnings << warning("repeated_history_rows") if (state.fetch("previous_ids") & rows.keys).any?
      consumed = state.fetch("offset") + rows.size
      warnings << warning("incomplete_history_page") if consumed > count || (rows.size < PAGE_SIZE && consumed < count)
      valuation = resource == "ledgers" && rows.any? ? valuation_for(account) : nil
      assets_response, pairs_response = catalogs if resource == "trades"
      asset_metadata, pair_metadata = result(assets_response), result(pairs_response) if resource == "trades"
      records = rows.filter_map do |id, raw|
        if resource == "trades"
          normalize_trade(id, raw, asset_metadata: asset_metadata, pair_metadata: pair_metadata)
        else
          normalize_ledger(id, raw, valuation: valuation)
        end
      rescue MissingValuation
        warnings << warning("missing_ledger_valuation")
        nil
      rescue Provider::AccountData::InvalidResponse
        warnings << warning("invalid_history_row")
        nil
      end
      complete = consumed == count && warnings.empty?
      continuation = if !complete && warnings.empty?
        encode_cursor(state.merge("offset" => consumed, "count" => count, "previous_ids" => rows.keys))
      end
      evidence = { "response" => response, "exchange_rates" => rate_evidence }
      evidence.merge!("asset_metadata" => assets_response, "pair_metadata" => pairs_response) if resource == "trades"
      evidence["valuation"] = valuation if valuation
      Provider::AccountData::Page.new(records: records, complete: complete, mode: "delta", next_cursor: continuation,
        progress_cursor: continuation, warnings: warnings, evidence: evidence,
        coverage: { "resource" => resource == "trades" ? "activity" : "transaction", "scope" => state["start"] ? "configured_history" : "all_history",
          "start" => state["start"] && Time.at(state["start"]).utc.iso8601, "end" => Time.at(state.fetch("end")).utc.iso8601,
          "pending_absence_authoritative" => false }.compact)
    rescue KeyError, TypeError, NoMethodError, ArgumentError, RangeError
      raise Provider::AccountData::InvalidResponse, "Invalid Kraken history response", cause: nil
    end

    def history_state(resource, cursor, window)
      if cursor
        raise ArgumentError unless cursor.is_a?(String) && cursor.bytesize <= 16_384
        state = JSON.parse(Base64.strict_decode64(cursor))
        unless state.is_a?(Hash) && state.keys.sort == %w[connection_id count currency end offset previous_ids resource start version] &&
            state["version"] == 1 && state["resource"] == resource && state["currency"] == currency && state["connection_id"] == @connection_id &&
            state["offset"].is_a?(Integer) && state["offset"] >= 0 && state["end"].is_a?(Integer) && state["end"].between?(1, observed_at.to_i) &&
            (state["start"].nil? || (state["start"].is_a?(Integer) && state["start"] >= 0 && state["start"] < state["end"])) &&
            state["count"].is_a?(Integer) && state["count"] > state["offset"] && state["previous_ids"].is_a?(Array) &&
            state["previous_ids"].size <= PAGE_SIZE && state["previous_ids"].all? { |id| id.is_a?(String) && id.present? }
          raise ArgumentError
        end
        return state
      end
      scope = normalized_object(window || {})
      from = scope[:explicit_start] ? Time.iso8601(scope.fetch(:start)).to_i : nil
      finish = scope[:end] ? [ Time.iso8601(scope[:end]).to_i, observed_at.to_i ].min : observed_at.to_i
      raise ArgumentError if from && from >= finish
      { "version" => 1, "connection_id" => @connection_id, "resource" => resource, "currency" => currency, "start" => from, "end" => finish,
        "offset" => 0, "count" => nil, "previous_ids" => [] }
    rescue JSON::ParserError, TypeError, ArgumentError
      raise Provider::AccountData::InvalidResponse, "Invalid Kraken history cursor", cause: nil
    end

    def encode_cursor(state)
      Base64.strict_encode64(JSON.generate(state))
    end

    def warning(code)
      { "code" => code, "provider_key" => "kraken" }
    end
end
