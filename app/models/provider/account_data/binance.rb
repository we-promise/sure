require "base64"
require "digest"
require "json"

class Provider::AccountData::Binance < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include Provider::AccountData::Binance::History

  SOURCES = %w[spot margin earn_flexible earn_locked futures].freeze
  STABLECOINS = %w[USDT BUSD FDUSD TUSD USDC DAI].freeze
  QUOTES = %w[USDT BUSD FDUSD BTC ETH BNB].freeze
  DEFINITION = Provider::AccountData::Definition.new(key: "binance", source: "binance", credential_scope: "connection",
    capabilities: %w[holdings activities], fields: [ { name: "api_key", type: "string", secret: true }, { name: "api_secret", type: "text", secret: true } ])

  def self.definition
    DEFINITION
  end

  def self.external_account_inputs
    { mutable: [], frozen: [ "metadata.portfolio_sources" ], inventory: "linked" }
  end

  def self.context_sources
    %i[external_accounts exchange_rate_resolver binance_history_seed]
  end

  def self.build(credentials:, settings:, context:)
    credentials = credentials.with_indifferent_access
    new(client: Provider::Binance.new(api_key: credentials.fetch(:api_key), api_secret: credentials.fetch(:api_secret)),
      currency: context.fetch(:family_currency), timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at),
      exchange_rate_resolver: context.fetch(:exchange_rate_resolver), external_accounts: context.fetch(:external_accounts, []),
      cached_history: context.fetch(:binance_history_seed).fetch("seed"))
  end

  def initialize(client:, currency:, timezone:, observed_at:, exchange_rate_resolver: nil, external_accounts: [], cached_history: {})
    super(client: client)
    @currency = normalized_currency(currency)
    @timezone, @observed_at, @exchange_rate_resolver = timezone, observed_at.to_time, exchange_rate_resolver
    existing = external_accounts.find { |row| normalized_object(row)[:external_id] == "combined" }
    @sources = normalized_object(existing ? normalized_object(existing).dig(:metadata, :portfolio_sources) || {} : {}).deep_dup
    @cached_history = normalized_object(cached_history)
    @price_cache = {}
  end

  def list_accounts(cursor: nil)
    ensure_requests_available!
    state = cursor ? decode_state(cursor, "inventory") : { "kind" => "inventory", "phase" => 0, "page" => 1, "observed_at" => observed_time }
    source = SOURCES.fetch(state.fetch("phase"))
    evidence, warnings = {}, []
    begin
      result = checked_page(client.get_portfolio_page(source, page: state.fetch("page")))
      read = normalize_assets(source, result[:items])
      previous = normalized_object(@sources[source] || {})
      pending = normalized_object(previous[:pending] || {})
      if state["page"] > 1
        unless pending[:observed_at] == state["observed_at"] && pending[:next_page] == state["page"]
          raise Provider::AccountData::IncompletePage, "Binance portfolio continuation lost its captured prefix"
        end
        read = merge_assets(Array(pending[:assets]) + read)
      end
      next_page = result[:next_cursor] && positive_integer(result[:next_cursor])
      raise ArgumentError if next_page && next_page <= state["page"]
      if next_page
        @sources[source] = previous.merge(pending: { assets: read, observed_at: state["observed_at"], next_page: next_page })
      else
        @sources[source] = { assets: read, observed_at: state["observed_at"], available: true, pending: nil }
      end
      evidence = { "source" => source, "response" => result[:evidence] || result[:items] }
    rescue Provider::Binance::RateLimitError
      @rate_limited = true
      raise Provider::AccountData::IncompletePage, "Binance portfolio was rate limited", cause: nil
    rescue Provider::Binance::Error => error
      @sources[source] = normalized_object(@sources[source] || {}).merge(available: false, pending: nil)
      warnings << { "code" => "portfolio_source_unavailable", "source" => source, "error_type" => error.class.name }
      evidence = { "source" => source, "unavailable" => true }
      next_page = nil
    end
    next_state = if next_page
      state.merge("page" => next_page)
    elsif state["phase"] + 1 < SOURCES.length
      state.merge("phase" => state["phase"] + 1, "page" => 1)
    end
    complete = next_state.nil? && SOURCES.all? { |key| current_source?(key, state["observed_at"]) }
    record = Ingestion::Record.account(external_id: "combined", name: "Binance", currency: nil, account_type: "Crypto",
      metadata: { portfolio_sources: @sources.deep_symbolize_keys, portfolio_observed_at: state["observed_at"],
        balance_provided: false, institution: { name: "Binance", domain: "binance.com" } })
    Provider::AccountData::Page.new(records: [ record ], complete: complete, mode: "snapshot",
      next_cursor: next_state && encode_state(next_state), warnings: warnings, evidence: evidence)
  rescue ArgumentError, TypeError, KeyError, NoMethodError, IndexError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance portfolio page", cause: nil
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    ensure_requests_available!
    assets, snapshots = portfolio(account)
    state = resource_state(cursor, "balance", assets)
    evidence = {}
    total = normalized_decimal(state.fetch("total", "0"))
    if state["index"] < assets.size
      asset = assets.fetch(state["index"])
      price, evidence = price_in_usd(asset[:symbol], quotes: [ "USDT" ])
      total += normalized_decimal(asset[:total]) * price
    end
    complete = state["index"] + 1 >= assets.size
    next_state = state.merge("index" => state["index"] + 1, "total" => total.to_s("F")) unless complete
    attributes = account.attributes.merge(balance: nil, cash_balance: nil,
      metadata: normalized_object(account[:metadata]).merge(balance_provided: false).deep_symbolize_keys)
    if complete
      amount, fx = from_usd(total.round(2), date: observation_date)
      attributes.merge!(balance: amount, cash_balance: BigDecimal("0"), currency: @currency,
        metadata: attributes[:metadata].merge(balance_provided: true, balance_policy: { cash_balance: "cash_balance" }, fx: fx))
      evidence = evidence.merge("fx" => fx)
    end
    continuation = next_state && encode_state(next_state)
    Provider::AccountData::Page.new(records: [ Ingestion::Record.account(**attributes) ], complete: complete, mode: "snapshot",
      next_cursor: continuation, progress_cursor: continuation, evidence: evidence,
      coverage: { "date" => observation_date.iso8601, "unavailable_sources" => unavailable_sources(snapshots) })
  rescue Provider::Binance::Error => error
    @rate_limited = true if error.is_a?(Provider::Binance::RateLimitError)
    raise Provider::AccountData::IncompletePage, "Binance account valuation is unavailable", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance balance", cause: nil
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    ensure_requests_available!
    linked_type = normalized_object(account[:metadata] || {})[:linked_account_type]
    if linked_type && linked_type != "Crypto"
      raise Provider::AccountData::UnsupportedCapability, "Binance positions require a linked crypto account"
    end
    assets, snapshots = portfolio(account)
    state = resource_state(cursor, "holdings", assets)
    records, evidence = [], {}
    if state["index"] < assets.size
      asset = assets.fetch(state["index"])
      price, evidence = price_in_usd(asset[:symbol], quotes: %w[USDT BUSD FDUSD])
      quantity = normalized_decimal(asset[:total])
      amount, fx = from_usd(quantity * price, date: observation_date)
      native_price, = from_usd(price, date: observation_date)
      records << Ingestion::Record.holding(external_id: "binance_#{asset[:symbol]}_#{asset[:source]}_#{observation_date}",
        quantity: quantity, price: native_price, amount: amount, currency: @currency, date: observation_date,
        security: security_descriptor(asset[:symbol]), metadata: { delete_future_holdings: false, portfolio_source: asset[:source] })
      evidence = evidence.merge("fx" => fx)
    end
    complete = state["index"] + 1 >= assets.size
    continuation = encode_state(state.merge("index" => state["index"] + 1)) unless complete
    Provider::AccountData::Page.new(records: records, complete: complete, mode: "snapshot", next_cursor: continuation,
      evidence: evidence, coverage: { "date" => observation_date.iso8601,
        "unavailable_sources" => unavailable_sources(snapshots), "absence_policy" => "requires_source_snapshot_reconciliation" })
  rescue Provider::Binance::Error => error
    @rate_limited = true if error.is_a?(Provider::Binance::RateLimitError)
    raise Provider::AccountData::IncompletePage, "Binance holding valuation is unavailable", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance holding", cause: nil
  end

  def normalize_assets(source, rows)
    records = rows.filter_map do |raw|
      data = normalized_object(raw)
      symbol = asset_symbol(data[:asset])
      free, locked, total = case source
      when "spot"
        free, locked = normalized_decimal(data.fetch(:free)), normalized_decimal(data.fetch(:locked))
        [ free, locked, free + locked ]
      when "margin"
        [ normalized_decimal(data.fetch(:free)), normalized_decimal(data.fetch(:locked)), normalized_decimal(data.fetch(:netAsset)) ]
      when "earn_flexible"
        value = normalized_decimal(data.fetch(:totalAmount))
        [ value, BigDecimal("0"), value ]
      when "earn_locked"
        value = normalized_decimal(data.fetch(:amount))
        [ BigDecimal("0"), value, value ]
      when "futures"
        wallet = normalized_decimal(data.fetch(:walletBalance))
        free = data[:availableBalance].nil? ? wallet : normalized_decimal(data[:availableBalance])
        [ free, wallet - free, wallet + normalized_decimal(data.fetch(:unrealizedProfit)) ]
      else raise ArgumentError
      end
      next if total.zero?
      { symbol: symbol, free: free.to_s("F"), locked: locked.to_s("F"), total: total.to_s("F") }
    end
    merge_assets(records)
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance asset quantities", cause: nil
  end

  private
    def ensure_requests_available!
      raise Provider::AccountData::IncompletePage, "Binance requests deferred after rate limiting" if @rate_limited
    end

    def observed_time
      @observed_at.iso8601(9)
    end

    def observation_date
      @observed_at.in_time_zone(@timezone).to_date
    end

    def current_source?(source, at)
      value = normalized_object(@sources[source] || {})
      value[:available] == true && value[:observed_at] == at && value[:assets].is_a?(Array)
    end

    def unavailable_sources(snapshots)
      SOURCES.reject { |key| snapshots.dig(key, :available) == true && snapshots.dig(key, :observed_at) == observed_time }
    end

    def portfolio(account)
      unless account[:external_id] == "combined"
        raise Provider::AccountData::UnsupportedCapability, "Legacy Binance account types require explicit topology reconciliation"
      end
      metadata = normalized_object(account[:metadata] || {})
      snapshots = normalized_object(metadata[:portfolio_sources] || {})
      if metadata[:portfolio_observed_at] != observed_time || SOURCES.all? { |key| snapshots.dig(key, :available) != true }
        raise Provider::AccountData::IncompletePage, "Binance portfolio has no current source observations"
      end
      assets = SOURCES.flat_map do |source|
        rows = snapshots.dig(source, :assets)
        raise Provider::AccountData::IncompletePage, "Binance unavailable source has no captured positions" unless rows.is_a?(Array)
        rows.map { |row| normalized_object(row).merge(source: source.start_with?("earn_") ? "earn" : source) }
      end
      grouped = assets.group_by { |row| [ row[:source], asset_symbol(row[:symbol]) ] }.map do |(source, symbol), rows|
        { source: source, symbol: symbol, total: rows.sum(BigDecimal("0")) { |row| normalized_decimal(row[:total]) }.to_s("F") }
      end.reject { |row| normalized_decimal(row[:total]).zero? }
      [ grouped.sort_by { |row| [ row[:source], row[:symbol] ] }, snapshots ]
    end

    def merge_assets(rows)
      rows.group_by { |raw| normalized_object(raw).fetch(:symbol) }.map do |symbol, items|
        { symbol: symbol }.merge(%i[free locked total].to_h do |key|
          [ key, items.sum(BigDecimal("0")) { |raw| normalized_decimal(normalized_object(raw).fetch(key)) }.to_s("F") ]
        end)
      end
    end

    def resource_state(cursor, kind, assets)
      digest = Digest::SHA256.hexdigest(JSON.generate(assets))
      state = cursor && decode_state(cursor, kind)
      return { "kind" => kind, "index" => 0, "snapshot" => digest, "observed_at" => observed_time } unless state &&
        state["snapshot"] == digest && state["observed_at"] == observed_time
      raise ArgumentError unless state["index"].is_a?(Integer) && state["index"] >= 0 && state["index"] <= assets.size
      state
    end

    def asset_symbol(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A[A-Z0-9]+\z/)
      value
    end

    def positive_integer(value)
      number = Integer(value, 10)
      raise ArgumentError unless number.positive?
      number
    end

    def security_descriptor(symbol)
      { ticker: "CRYPTO:#{asset_symbol(symbol)}", name: symbol, fallback_offline: true, fallback_exchange_operating_mic: "XBNC" }
    end

    def from_usd(amount, date:)
      return [ amount, { "stale_rate" => false } ] if @currency == "USD"
      rate = fx_rate("USD", @currency, date)
      raise Provider::AccountData::IncompletePage, "Binance native valuation has no exchange rate" unless rate
      actual_date = rate.fetch(:date)
      [ Money.new(amount, "USD").exchange_to(@currency, custom_rate: rate.fetch(:rate)).amount,
        { "stale_rate" => actual_date != date.iso8601, "rate_date_used" => actual_date, "rate_target_date" => date.iso8601,
          "rate" => rate.fetch(:rate), "from" => "USD", "to" => @currency } ]
    end

    def fx_rate(from, to, date)
      value = @exchange_rate_resolver&.call(from: from, to: to, date: date)
      return nil unless value
      result = normalized_object(value)
      rate = normalized_decimal(result.fetch(:rate))
      raise ArgumentError unless rate.positive? && result[:date].is_a?(String)
      Date.iso8601(result[:date])
      { rate: rate, date: result[:date] }
    end

    def price_in_usd(symbol, quotes: [ "USDT" ], date: nil, allow_fx: true)
      ensure_requests_available!
      return [ BigDecimal("1"), { "valuation" => "stablecoin_parity", "asset" => symbol } ] if STABLECOINS.include?(symbol) || symbol == "USD"
      key = [ symbol, quotes, date, allow_fx ]
      return @price_cache[key] if @price_cache.key?(key)
      evidence = []
      quotes.each do |quote|
        [ date, nil ].uniq.each do |day|
          begin
            result = checked_page(client.get_price_page("#{symbol}#{quote}", date: day))
            evidence << { "symbol" => "#{symbol}#{quote}", "date" => day&.iso8601, "response" => result[:evidence] || result[:items] }
            next if result[:items].empty?
            raise ArgumentError unless result[:items].one? && result[:next_cursor].nil?
            price = normalized_decimal(normalized_object(result[:items].first).fetch(:price))
            raise ArgumentError unless price.positive?
            return @price_cache[key] = [ price, { "prices" => evidence } ]
          rescue Provider::Binance::InvalidSymbolError, Provider::Binance::ApiError
            next
          end
        end
      end
      if date && allow_fx && (rate = fx_rate(symbol, "USD", date))
        return @price_cache[key] = [ rate[:rate], { "prices" => evidence, "exchange_rate" => rate } ]
      end
      raise Provider::AccountData::IncompletePage, "Binance asset valuation is unavailable"
    end

    def encode_state(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def decode_state(cursor, kind)
      state = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise ArgumentError unless state.is_a?(Hash) && state["kind"] == kind && state["observed_at"].is_a?(String)
      Time.iso8601(state["observed_at"])
      case kind
      when "inventory"
        raise ArgumentError unless state.keys.sort == %w[kind observed_at page phase] &&
          state["phase"].is_a?(Integer) && state["phase"].between?(0, SOURCES.size - 1) &&
          state["page"].is_a?(Integer) && state["page"].positive?
      when "balance", "holdings"
        allowed = %w[index kind observed_at snapshot] + (kind == "balance" ? [ "total" ] : [])
        raise ArgumentError unless (state.keys - allowed).empty? && state["snapshot"].is_a?(String) && state["snapshot"].match?(/\A[0-9a-f]{64}\z/) &&
          state["index"].is_a?(Integer) && state["index"] >= 0
        normalized_decimal(state["total"]) if state.key?("total")
      when "activities"
        validate_history_state!(state)
      else raise ArgumentError
      end
      state
    end
end
