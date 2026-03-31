require "set"

class BinanceItem::Importer
  DEFAULT_HISTORY_LOOKBACK = 5.years
  TRANSFER_WINDOW = 89.days
  TRADE_WINDOW = 1.day
  USD_STABLECOINS = %w[USDT USDC FDUSD BUSD].freeze
  PREFERRED_QUOTES = %w[USD EUR USDT USDC FDUSD BUSD BTC ETH BNB TRY].freeze
  MAJOR_BASE_ASSETS = %w[
    BTC ETH BNB SOL XRP ADA DOGE LTC TRX DOT AVAX ATOM LINK MATIC POL
    USDT USDC FDUSD BUSD EUR TRY
  ].freeze

  attr_reader :binance_item, :binance_provider

  def initialize(binance_item, binance_provider:)
    @binance_item = binance_item
    @binance_provider = binance_provider
    @historical_close_cache = {}
    @historical_rate_cache = {}
    @current_rate_cache = {}
  end

  def import
    Rails.logger.info "BinanceItem::Importer - Starting import for item #{binance_item.id}"

    account_data = binance_provider.get_account(omit_zero_balances: true)
    coins_info = index_by_coin(binance_provider.get_all_coin_info)
    exchange_symbols = Array(binance_provider.get_exchange_info["symbols"])
    @pair_index = build_pair_index(exchange_symbols)
    @current_prices = binance_provider.get_all_prices

    valuation_currency = determine_valuation_currency
    holdings_snapshot = build_holdings_snapshot(
      balances: Array(account_data["balances"]),
      coins_info: coins_info,
      valuation_currency: valuation_currency
    )

    deposits = fetch_deposit_history(valuation_currency: valuation_currency)
    withdrawals = fetch_withdraw_history(valuation_currency: valuation_currency)
    candidate_symbols = discover_trade_symbols(
      exchange_symbols: exchange_symbols,
      balances: Array(account_data["balances"]),
      deposits: deposits,
      withdrawals: withdrawals
    )
    trades = fetch_trade_history(candidate_symbols: candidate_symbols, valuation_currency: valuation_currency)

    upsert_provider_account!(
      account_data: account_data,
      holdings_snapshot: holdings_snapshot,
      deposits: deposits,
      withdrawals: withdrawals,
      trades: trades,
      candidate_symbols: candidate_symbols.map { |symbol| symbol["symbol"] },
      valuation_currency: valuation_currency
    )

    binance_item.upsert_binance_snapshot!(
      "account" => account_data,
      "holdings_count" => holdings_snapshot.size,
      "candidate_symbols" => candidate_symbols.map { |symbol| symbol["symbol"] },
      "fetched_at" => Time.current.iso8601
    )

    {
      success: true,
      accounts_imported: 1,
      holdings_imported: holdings_snapshot.size,
      trades_imported: trades.size,
      transfers_imported: deposits.size + withdrawals.size
    }
  end

  private

    def provider_account
      @provider_account ||= binance_item.binance_accounts.first
    end

    def determine_valuation_currency
      binance_item.family.currency.to_s.upcase.presence || "USD"
    end

    def history_start_time
      return binance_item.last_synced_at - 1.day if binance_item.last_synced_at.present?
      return binance_item.sync_start_date.to_time.beginning_of_day if binance_item.sync_start_date.present?

      DEFAULT_HISTORY_LOOKBACK.ago.beginning_of_day
    end

    def index_by_coin(coins_info)
      Array(coins_info).index_by { |coin| coin["coin"] }
    end

    def build_pair_index(exchange_symbols)
      exchange_symbols.each_with_object({}) do |symbol_data, index|
        next unless symbol_data["symbol"].present?

        index[[ symbol_data["baseAsset"], symbol_data["quoteAsset"] ]] = symbol_data["symbol"]
      end
    end

    def build_holdings_snapshot(balances:, coins_info:, valuation_currency:)
      balances.filter_map do |balance|
        quantity = decimal(balance["free"]) + decimal(balance["locked"])
        next if quantity <= 0

        asset = balance["asset"].to_s.upcase
        rate = current_conversion_rate(asset, valuation_currency)
        amount = rate ? (quantity * rate).round(2) : nil

        {
          "asset" => asset,
          "name" => coins_info.dig(asset, "name") || asset,
          "quantity" => decimal_string(quantity),
          "free" => decimal_string(balance["free"]),
          "locked" => decimal_string(balance["locked"]),
          "price" => rate ? decimal_string(rate.round(8)) : nil,
          "amount" => amount ? decimal_string(amount) : nil,
          "currency" => valuation_currency,
          "valuation_source" => rate ? "current" : "missing"
        }.compact
      end
    end

    def fetch_deposit_history(valuation_currency:)
      fetch_windowed_history do |start_time:, end_time:, offset:, limit:|
        binance_provider.get_deposit_history(
          start_time: start_time,
          end_time: end_time,
          offset: offset,
          limit: limit
        )
      end.filter_map do |deposit|
        next unless deposit["status"].to_i == 1

        date = deposit_date(deposit)
        rate, source = valued_rate_for(
          asset: deposit["coin"],
          date: date,
          valuation_currency: valuation_currency
        )

        deposit.merge(
          "valuation_currency" => valuation_currency,
          "valuation_rate" => rate ? decimal_string(rate.round(8)) : nil,
          "valuation_amount" => rate ? decimal_string((decimal(deposit["amount"]) * rate).round(2)) : nil,
          "valuation_source" => source
        )
      end
    end

    def fetch_withdraw_history(valuation_currency:)
      fetch_windowed_history do |start_time:, end_time:, offset:, limit:|
        binance_provider.get_withdraw_history(
          start_time: start_time,
          end_time: end_time,
          offset: offset,
          limit: limit
        )
      end.filter_map do |withdrawal|
        next unless withdrawal["status"].to_i == 6

        date = withdraw_date(withdrawal)
        rate, source = valued_rate_for(
          asset: withdrawal["coin"],
          date: date,
          valuation_currency: valuation_currency
        )

        withdrawal.merge(
          "valuation_currency" => valuation_currency,
          "valuation_rate" => rate ? decimal_string(rate.round(8)) : nil,
          "valuation_amount" => rate ? decimal_string((decimal(withdrawal["amount"]) * rate).round(2)) : nil,
          "fee_valuation_amount" => rate ? decimal_string((decimal(withdrawal["transactionFee"]) * rate).round(2)) : nil,
          "valuation_source" => source
        )
      end
    end

    def fetch_windowed_history(limit: 1000)
      results = []
      window_start = history_start_time
      now = Time.current

      while window_start <= now
        window_end = [ window_start + TRANSFER_WINDOW, now ].min
        offset = 0

        loop do
          page = Array(yield(
            start_time: window_start.to_i * 1000,
            end_time: window_end.to_i * 1000,
            offset: offset,
            limit: limit
          ))
          break if page.empty?

          results.concat(page)
          break if page.size < limit

          offset += limit
        end

        window_start = window_end + 1.second
      end

      results
    end

    def discover_trade_symbols(exchange_symbols:, balances:, deposits:, withdrawals:)
      previous_symbols = Array(provider_account&.raw_transactions_payload&.dig("candidate_symbols"))
      symbol_index = exchange_symbols.index_by { |symbol| symbol["symbol"] }

      seen_assets = Set.new
      Array(balances).each { |balance| seen_assets << balance["asset"].to_s.upcase }
      deposits.each { |deposit| seen_assets << deposit["coin"].to_s.upcase }
      withdrawals.each { |withdrawal| seen_assets << withdrawal["coin"].to_s.upcase }

      discovered = exchange_symbols.select do |symbol_data|
        next false unless symbol_data["status"] == "TRADING"

        base_asset = symbol_data["baseAsset"].to_s.upcase
        quote_asset = symbol_data["quoteAsset"].to_s.upcase

        (seen_assets.include?(base_asset) && (seen_assets.include?(quote_asset) || preferred_quotes.include?(quote_asset))) ||
          (seen_assets.include?(quote_asset) && major_base_assets.include?(base_asset))
      end

      merged = (discovered.map { |symbol| symbol["symbol"] } + previous_symbols).uniq
      merged.filter_map { |symbol| symbol_index[symbol] }
    end

    def fetch_trade_history(candidate_symbols:, valuation_currency:)
      return [] if candidate_symbols.empty?

      trades = if binance_item.last_synced_at.present?
        fetch_recent_trades(candidate_symbols: candidate_symbols)
      else
        fetch_full_trades(candidate_symbols: candidate_symbols)
      end

      trades.uniq { |trade| [ trade["symbol"], trade["id"] ] }.map do |trade|
        date = Time.zone.at(trade["time"].to_i / 1000.0).to_date
        rate, source = valued_rate_for(
          asset: trade["quote_asset"],
          date: date,
          valuation_currency: valuation_currency
        )
        commission_rate, commission_source = valued_rate_for(
          asset: trade["commissionAsset"],
          date: date,
          valuation_currency: valuation_currency
        )

        trade.merge(
          "valuation_currency" => valuation_currency,
          "valuation_rate" => rate ? decimal_string(rate.round(8)) : nil,
          "valuation_amount" => rate ? decimal_string((decimal(trade["quoteQty"]) * rate).round(2)) : nil,
          "valuation_price" => rate ? decimal_string((decimal(trade["price"]) * rate).round(8)) : nil,
          "valuation_source" => source,
          "commission_asset" => trade["commissionAsset"],
          "commission_valuation_rate" => commission_rate ? decimal_string(commission_rate.round(8)) : nil,
          "commission_valuation_amount" => commission_rate ? decimal_string((decimal(trade["commission"]) * commission_rate).round(2)) : nil,
          "commission_valuation_source" => commission_source
        )
      end
    end

    def fetch_recent_trades(candidate_symbols:)
      trades = []
      window_start = history_start_time
      now = Time.current

      while window_start <= now
        window_end = [ window_start + TRADE_WINDOW - 1.second, now ].min
        candidate_symbols.each do |symbol_data|
          page = Array(binance_provider.get_my_trades(
            symbol: symbol_data["symbol"],
            start_time: window_start.to_i * 1000,
            end_time: window_end.to_i * 1000,
            limit: 1000
          ))
          trades.concat(enrich_trade_records(page, symbol_data))
        end
        window_start = window_end + 1.second
      end

      trades
    end

    def fetch_full_trades(candidate_symbols:)
      candidate_symbols.flat_map do |symbol_data|
        from_id = nil
        records = []

        loop do
          page = Array(binance_provider.get_my_trades(
            symbol: symbol_data["symbol"],
            from_id: from_id,
            limit: 1000
          ))
          break if page.empty?

          records.concat(enrich_trade_records(page, symbol_data))
          break if page.size < 1000

          from_id = page.last["id"].to_i + 1
        end

        records
      end
    end

    def enrich_trade_records(records, symbol_data)
      records.map do |trade|
        trade.merge(
          "symbol" => symbol_data["symbol"],
          "base_asset" => symbol_data["baseAsset"],
          "quote_asset" => symbol_data["quoteAsset"]
        )
      end
    end

    def upsert_provider_account!(account_data:, holdings_snapshot:, deposits:, withdrawals:, trades:, candidate_symbols:, valuation_currency:)
      uid = account_data["uid"].presence || "spot"
      total_value = holdings_snapshot.sum { |holding| decimal(holding["amount"]) }
      provider_account = binance_item.binance_accounts.find_or_initialize_by(account_id: uid.to_s)

      provider_account.upsert_from_binance!(
        name: "Binance Spot",
        account_id: uid.to_s,
        currency: valuation_currency,
        current_balance: total_value.round(2),
        cash_balance: 0,
        status: account_data["canTrade"] ? "active" : "restricted",
        account_type: account_data["accountType"].to_s.downcase.presence || "spot",
        provider: "binance",
        institution_metadata: {
          "name" => "Binance",
          "domain" => "binance.com",
          "url" => "https://www.binance.com",
          "permissions" => Array(account_data["permissions"]),
          "valuation_currency" => valuation_currency
        },
        raw_payload: account_data,
        raw_holdings_payload: holdings_snapshot
      )

      provider_account.upsert_transactions_snapshot!(
        "candidate_symbols" => candidate_symbols,
        "trades" => trades,
        "deposits" => deposits,
        "withdrawals" => withdrawals,
        "fetched_at" => Time.current.iso8601
      )
    end

    def preferred_quotes
      @preferred_quotes ||= (PREFERRED_QUOTES + [ determine_valuation_currency ]).uniq
    end

    def major_base_assets
      @major_base_assets ||= MAJOR_BASE_ASSETS
    end

    def current_conversion_rate(asset, target_currency, depth: 0, visited: Set.new)
      key = [ asset, target_currency, depth, visited.to_a.sort ]
      return @current_rate_cache[key] if @current_rate_cache.key?(key)

      result = if asset == target_currency || stablecoin_equivalent?(asset, target_currency)
        BigDecimal("1")
      elsif depth > 2 || visited.include?(asset)
        nil
      else
        direct_pair_rate(asset, target_currency, prices: @current_prices) ||
          preferred_quotes.filter_map do |intermediate|
            next if intermediate == asset || intermediate == target_currency

            first_leg = direct_pair_rate(asset, intermediate, prices: @current_prices)
            next unless first_leg

            second_leg = current_conversion_rate(
              intermediate,
              target_currency,
              depth: depth + 1,
              visited: visited | Set.new([ asset ])
            )
            next unless second_leg

            first_leg * second_leg
          end.first
      end

      @current_rate_cache[key] = result
    end

    def valued_rate_for(asset:, date:, valuation_currency:)
      historical_rate = historical_conversion_rate(asset, valuation_currency, date)
      return [ historical_rate, "historical" ] if historical_rate

      current_rate = current_conversion_rate(asset, valuation_currency)
      return [ current_rate, "current" ] if current_rate

      [ nil, "missing" ]
    end

    def historical_conversion_rate(asset, target_currency, date, depth: 0, visited: Set.new)
      key = [ asset, target_currency, date, depth, visited.to_a.sort ]
      return @historical_rate_cache[key] if @historical_rate_cache.key?(key)

      result = if asset == target_currency || stablecoin_equivalent?(asset, target_currency)
        BigDecimal("1")
      elsif depth > 2 || visited.include?(asset)
        nil
      else
        direct_pair_rate(asset, target_currency, date: date) ||
          preferred_quotes.filter_map do |intermediate|
            next if intermediate == asset || intermediate == target_currency

            first_leg = direct_pair_rate(asset, intermediate, date: date)
            next unless first_leg

            second_leg = historical_conversion_rate(
              intermediate,
              target_currency,
              date,
              depth: depth + 1,
              visited: visited | Set.new([ asset ])
            )
            next unless second_leg

            first_leg * second_leg
          end.first
      end

      @historical_rate_cache[key] = result
    end

    def direct_pair_rate(base_asset, quote_asset, date: nil, prices: nil)
      return BigDecimal("1") if base_asset == quote_asset
      return BigDecimal("1") if stablecoin_equivalent?(base_asset, quote_asset)

      direct_symbol = @pair_index[[ base_asset, quote_asset ]]
      if direct_symbol
        direct_rate = date ? historical_close(direct_symbol, date) : prices[direct_symbol]
        return direct_rate if direct_rate&.positive?
      end

      reverse_symbol = @pair_index[[ quote_asset, base_asset ]]
      if reverse_symbol
        reverse_rate = date ? historical_close(reverse_symbol, date) : prices[reverse_symbol]
        return (BigDecimal("1") / reverse_rate) if reverse_rate&.positive?
      end

      nil
    end

    def historical_close(symbol, date)
      cache_key = [ symbol, date ]
      return @historical_close_cache[cache_key] if @historical_close_cache.key?(cache_key)

      kline = Array(binance_provider.get_daily_klines(symbol: symbol, date: date)).first
      close_price = kline.present? ? decimal(kline[4]) : nil
      @historical_close_cache[cache_key] = close_price
    end

    def stablecoin_equivalent?(base_asset, quote_asset)
      (base_asset == "USD" && USD_STABLECOINS.include?(quote_asset)) ||
        (quote_asset == "USD" && USD_STABLECOINS.include?(base_asset))
    end

    def deposit_date(deposit)
      parse_milliseconds_or_string(deposit["completeTime"]) ||
        parse_milliseconds_or_string(deposit["insertTime"]) ||
        Date.current
    end

    def withdraw_date(withdrawal)
      parse_milliseconds_or_string(withdrawal["completeTime"]) ||
        parse_milliseconds_or_string(withdrawal["applyTime"]) ||
        Date.current
    end

    def parse_milliseconds_or_string(value)
      case value
      when Integer
        Time.zone.at(value / 1000.0).to_date
      when Float
        Time.zone.at(value / 1000.0).to_date
      when String
        return nil if value.blank?

        if value.match?(/\A\d+\z/)
          Time.zone.at(value.to_f / 1000.0).to_date
        else
          Time.find_zone!("UTC").parse(value).to_date
        end
      end
    rescue ArgumentError, TypeError
      nil
    end

    def decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def decimal_string(value)
      value.to_d.to_s("F")
    end
end
