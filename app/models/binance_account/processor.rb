# frozen_string_literal: true

# Updates account balance and imports spot trades.
class BinanceAccount::Processor
  include BinanceAccount::UsdConverter

  # Quote currencies probed when fetching trade history. Ordered by prevalence so
  # the most common pairs are tried first and rate-limit weight is front-loaded.
  TRADE_QUOTE_CURRENCIES = %w[USDT BUSD FDUSD BTC ETH BNB].freeze

  attr_reader :binance_account

  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    unless binance_account.current_account.present?
      Rails.logger.info "BinanceAccount::Processor - no linked account for #{binance_account.id}, skipping"
      return
    end

    begin
      BinanceAccount::HoldingsProcessor.new(binance_account).process
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - holdings failed for #{binance_account.id}: #{e.message}"
    end

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - account update failed for #{binance_account.id}: #{e.message}"
      raise
    end

    fetch_and_process_trades
  end

  private

    def target_currency
      binance_account.binance_item.family.currency
    end

    def process_account!
      account  = binance_account.current_account
      raw_usd  = (binance_account.current_balance || 0).to_d
      amount, stale, rate_date = convert_from_usd(raw_usd, date: Date.current)
      stale_extra = build_stale_extra(stale, rate_date, Date.current)

      account.update!(
        balance:      amount,
        cash_balance: 0,
        currency:     target_currency
      )

      binance_account.update!(extra: binance_account.extra.to_h.deep_merge(stale_extra))
    end

    def fetch_and_process_trades
      provider = binance_account.binance_item&.binance_provider
      return unless provider

      # 1. Initialize data from existing payload
      existing_spot    = binance_account.raw_transactions_payload&.dig("spot") || {}
      existing_futures = binance_account.raw_transactions_payload&.dig("futures") || {}
      existing_p2p     = binance_account.raw_transactions_payload&.dig("p2p") || []

      # 2. Fetch P2P Trades (This now runs even if you have no spot assets)
      new_p2p = fetch_new_p2p_trades(provider, existing_p2p)

      # 3. Handle Spot & Futures symbols
      symbols = extract_trade_symbols
      new_trades_by_symbol = {}
      new_futures_by_symbol = {}

      # Only attempt to loop if we actually have symbols (e.g., BTC, ETH)
      if symbols.any?
        symbols.each do |symbol|
          TRADE_QUOTE_CURRENCIES.each do |quote|
            pair = "#{symbol}#{quote}"
            begin
              new_trades = fetch_new_trades(provider, pair, existing_spot[pair], :spot)
              new_trades_by_symbol[pair] = new_trades if new_trades.present?
            rescue Provider::Binance::InvalidSymbolError => e
              Rails.logger.debug "BinanceAccount::Processor - skipping spot #{pair}: #{e.message}"
            end

            begin
              new_futures = fetch_new_trades(provider, pair, existing_futures[pair], :futures)
              new_futures_by_symbol[pair] = new_futures if new_futures.present?
            rescue Provider::Binance::InvalidSymbolError => e
              Rails.logger.debug "BinanceAccount::Processor - skipping futures #{pair}: #{e.message}"
            end
          end
        end
      end

      # 4. Process New Records into Database Entries FIRST
      # We process these into the DB first. If they fail or raise an error,
      # the method halts before updating the raw_transactions_payload cache,
      # ensuring a retry happens on the next sync execution.
      process_trades(new_trades_by_symbol, :spot) if new_trades_by_symbol.any?
      process_trades(new_futures_by_symbol, :futures) if new_futures_by_symbol.any?
      process_p2p_trades(new_p2p) if new_p2p.any?

      # 5. Merge Results ONLY after successful DB insertion
      merged_spot    = existing_spot.merge(new_trades_by_symbol) { |_pair, old, new_t| old + new_t }
      merged_futures = existing_futures.merge(new_futures_by_symbol) { |_pair, old, new_t| old + new_t }
      merged_p2p     = existing_p2p + new_p2p

      # 6. Update the Account Payload LAST (Safe Caching Boundary)
      binance_account.update!(raw_transactions_payload: {
        "spot"       => merged_spot,
        "futures"    => merged_futures,
        "p2p"        => merged_p2p,
        "fetched_at" => Time.current.iso8601
      })
    end

    # Fetches only trades newer than what is already cached for the given pair.
    # On the first sync (no cached trades) fetches the most recent page.
    # On subsequent syncs starts from max_cached_id + 1 and paginates forward.
    def fetch_new_trades(provider, pair, cached_trades, market_type)
      limit = 1000
      max_cached_id = cached_trades&.map { |t| t["id"].to_i }&.max

      from_id = max_cached_id ? max_cached_id + 1 : nil
      start_time = nil
      unless max_cached_id
        start_time = binance_account.binance_item&.sync_start_date&.to_time&.to_i&.*(1000)
      end
      all_new = []

      loop do
        page = if market_type == :spot
          provider.get_spot_trades(pair, limit: limit, from_id: from_id, startTime: start_time)
        else
          provider.get_futures_trades(pair, limit: limit, from_id: from_id, startTime: start_time)
        end
        break if page.blank?

        all_new.concat(page)
        break if page.size < limit

        from_id = page.map { |t| t["id"].to_i }.max + 1
      end

      all_new
    end

    def fetch_new_p2p_trades(provider, cached_p2p)
      # Binance P2P history endpoint only supports max 30-day windows.
      # If no cache exists, we fetch back to sync_start_date (or default 30 days).
      # If cache exists, we fetch from the last cached trade timestamp.
      max_cached_timestamp = cached_p2p&.map { |t| t["createTime"].to_i }&.max

      start_time = if max_cached_timestamp
        max_cached_timestamp
      elsif binance_account.binance_item&.sync_start_date
        binance_account.binance_item.sync_start_date.to_time.to_i * 1000
      else
        (Time.current - 30.days).to_i * 1000
      end

      all_new = []
      current_start = start_time

      loop do
        current_end = [ current_start + 30.days.to_i * 1000, Time.current.to_i * 1000 ].min

        page = provider.get_all_p2p_trades(start_timestamp: current_start, end_timestamp: current_end)

        # We might fetch overlapping trades if they share the exact timestamp, filter by unique orderNumber
        if page.present?
          cached_order_numbers = cached_p2p&.map { |t| t["orderNumber"] } || []
          new_order_numbers = all_new.map { |t| t["orderNumber"] }

          unique_page = page.reject do |t|
            cached_order_numbers.include?(t["orderNumber"]) || new_order_numbers.include?(t["orderNumber"])
          end

          all_new.concat(unique_page)
        end

        break if current_end >= Time.current.to_i * 1000
        current_start = current_end + 1
      end

      all_new
    end

    def extract_trade_symbols
      stablecoins = BinanceAccount::STABLECOINS
      quote_re    = /(#{TRADE_QUOTE_CURRENCIES.join("|")})$/

      # Base symbols from today's asset snapshot
      assets  = binance_account.raw_payload&.dig("assets") || []
      current = assets.map { |a| a["symbol"] || a[:symbol] }.compact

      # Base symbols from previously fetched pairs (recovers sold-out assets)
      prev_spot    = binance_account.raw_transactions_payload&.dig("spot")&.keys || []
      prev_futures = binance_account.raw_transactions_payload&.dig("futures")&.keys || []
      prev_pairs   = (prev_spot + prev_futures).uniq
      previous   = prev_pairs.map { |pair| pair.gsub(quote_re, "") }

      (current + previous).uniq.compact.reject { |s| s.blank? || stablecoins.include?(s) }
    end

    def process_trades(trades_by_symbol, market_type)
      trades_by_symbol.each do |pair, trades|
        trades.each { |trade| process_trade(trade, pair, market_type) }
      end
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - trade processing failed: #{e.message}"
      raise
    end

    def process_trade(trade, pair, market_type)
      account = binance_account.current_account
      return unless account

      quote_suffix = TRADE_QUOTE_CURRENCIES.find { |q| pair.end_with?(q) }
      base_symbol  = quote_suffix ? pair.delete_suffix(quote_suffix) : pair
      return if base_symbol.blank?

      ticker   = "CRYPTO:#{base_symbol}"
      security = BinanceAccount::SecurityResolver.resolve(ticker, base_symbol)

      return unless security

      prefix = market_type == :spot ? "spot" : "futures"
      external_id = "binance_#{prefix}_#{pair}_#{trade["id"]}"
      return if account.entries.exists?(external_id: external_id)

      date       = Time.zone.at(trade["time"].to_i / 1000).to_date
      qty        = trade["qty"].to_d
      price_raw  = trade["price"].to_d
      quote_qty  = trade["quoteQty"].to_d

      # quoteQty and price are denominated in the quote currency (e.g. BTC for ETHBTC).
      # Convert to USD so all entries and cost-basis calculations share a common currency.
      quote_symbol  = quote_suffix || "USDT"
      amount_usd_raw = quote_to_usd(quote_qty, quote_symbol, date: date)
      price_usd      = quote_to_usd(price_raw, quote_symbol, date: date)

      if amount_usd_raw.nil? || price_usd.nil?
        Rails.logger.warn "BinanceAccount::Processor - skipping trade #{trade["id"]} for #{pair}: could not convert #{quote_symbol} to USD"
        return
      end

      amount_usd  = amount_usd_raw.round(2)
      commission  = commission_in_usd(trade, base_symbol, price_usd, date: date)
      is_buyer     = trade.key?("isBuyer") ? trade["isBuyer"] : trade["buyer"]

      if is_buyer
        account.entries.create!(
          date:        date,
          name:        "Buy #{qty.round(8)} #{base_symbol}",
          amount:      -amount_usd,
          currency:    "USD",
          external_id: external_id,
          source:      "binance",
          entryable:   Trade.new(
            security:                  security,
            qty:                       qty,
            price:                     price_usd,
            currency:                  "USD",
            fee:                       commission,
            investment_activity_label: "Buy"
          )
        )
      else
        account.entries.create!(
          date:        date,
          name:        "Sell #{qty.round(8)} #{base_symbol}",
          amount:      amount_usd,
          currency:    "USD",
          external_id: external_id,
          source:      "binance",
          entryable:   Trade.new(
            security:                  security,
            qty:                       -qty,
            price:                     price_usd,
            currency:                  "USD",
            fee:                       commission,
            investment_activity_label: "Sell"
          )
        )
      end
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - failed to process trade #{trade["id"]}: #{e.message}"
      raise
    end

    # Converts an amount denominated in quote_symbol to USD.
    # Stablecoins are treated as 1:1.
    # For fiat/crypto assets, tries Binance historical price first, falls back to internal ExchangeRate.
    def quote_to_usd(amount, quote_symbol, date: nil)
      return amount if BinanceAccount::STABLECOINS.include?(quote_symbol)
      return amount if quote_symbol.to_s.upcase == "USD"

      provider = binance_account.binance_item&.binance_provider

      if provider
        spot = nil
        begin
          spot = provider.get_historical_price("#{quote_symbol}USDT", date) if date.present? && provider.respond_to?(:get_historical_price)
          spot ||= provider.get_spot_price("#{quote_symbol}USDT")
        rescue Provider::Binance::InvalidSymbolError
          # Fall through to ExchangeRate lookup
        end
        return (amount * spot.to_d).round(8) if spot.present?
      end

      # Fallback to internal app ExchangeRate provider (crucial for P2P fiat currencies like TZS, NGN)
      fallback_rate = ExchangeRate.find_or_fetch_rate(from: quote_symbol, to: "USD", date: date || Date.current, cache: true)
      if fallback_rate.present?
        # Extract the numeric rate from the returned object (or use it directly if it's already a number)
        rate_val = fallback_rate.respond_to?(:rate) ? fallback_rate.rate : fallback_rate
        return (amount * rate_val.to_d).round(8)
      end

      nil
    rescue StandardError => e
      Rails.logger.warn "BinanceAccount::Processor - could not convert #{quote_symbol} to USD: #{e.message}"
      nil
    end

    # Converts the trade commission to USD.
    # commissionAsset can be: a stablecoin (≈ 1 USD), the base asset, or something else (e.g. BNB).
    def process_p2p_trades(trades)
      account = binance_account.current_account
      return unless account

      Rails.logger.info "BinanceAccount::Processor - found #{trades.size} P2P trades to process"

      trades.each do |trade|
        external_id = "binance_p2p_#{trade["orderNumber"]}"
        funding_external_id = "#{external_id}_funding"

        # Deduplicate by checking for either the Trade or Funding leg in a single query
        if account.entries.where(external_id: [ external_id, funding_external_id ]).exists?
          Rails.logger.info "BinanceAccount::Processor - skipping P2P trade #{trade["orderNumber"]}: already exists in DB"
          next
        end

        date = Time.zone.at(trade["createTime"].to_i / 1000).to_date
        trade_type = trade["tradeType"] # BUY or SELL

        begin
          # Grab the exact Fiat and Crypto truth straight from the payload
          fiat_currency = trade["fiat"]
          fiat_amount   = trade["totalPrice"].to_d
          fiat_price    = trade["unitPrice"].to_d

          crypto_asset  = trade["asset"]
          gross_crypto  = trade["amount"].to_d
          net_crypto    = (trade["takerAmount"] || gross_crypto).to_d
          crypto_fee    = (trade["takerCommission"] || 0).to_d

          ticker   = "CRYPTO:#{crypto_asset}"
          security = BinanceAccount::SecurityResolver.resolve(ticker, crypto_asset)

          unless security
            Rails.logger.warn "BinanceAccount::Processor - skipping P2P trade #{trade["orderNumber"]}: could not resolve security for #{crypto_asset}"
            next
          end

          # Convert the crypto fee (if any) to its fiat equivalent using the trade's exact unit price
          fiat_fee = (crypto_fee * fiat_price).round(2)

          # 3. AI Fix: Wrap the double-entry in a transaction block to guarantee ledger integrity
          account.transaction do
            if trade_type == "BUY"
              # BUY LOGIC: User sent Fiat from their bank, received Crypto
              account.entries.create!(
                date:        date,
                name:        "P2P Payment (#{fiat_currency})",
                amount:      -fiat_amount, # Fiat leaving the system
                currency:    fiat_currency,
                external_id: funding_external_id,
                source:      "binance",
                entryable:   Transaction.new
              )

              account.entries.create!(
                date:        date,
                name:        "P2P Buy #{gross_crypto.round(8)} #{crypto_asset}",
                amount:      fiat_amount, # Fiat value entering as Crypto (Cost Basis)
                currency:    fiat_currency,
                external_id: external_id,
                source:      "binance",
                entryable:   Trade.new(
                  security:                  security,
                  qty:                       net_crypto,
                  price:                     fiat_price,
                  currency:                  fiat_currency,
                  fee:                       fiat_fee,
                  investment_activity_label: "Buy"
                )
              )
            else
              # SELL LOGIC: User liquidated Crypto, received Fiat to their bank
              account.entries.create!(
                date:        date,
                name:        "P2P Sell #{gross_crypto.round(8)} #{crypto_asset}",
                amount:      -fiat_amount, # Fiat value of Crypto leaving
                currency:    fiat_currency,
                external_id: external_id,
                source:      "binance",
                entryable:   Trade.new(
                  security:                  security,
                  qty:                       -net_crypto,
                  price:                     fiat_price,
                  currency:                  fiat_currency,
                  fee:                       fiat_fee,
                  investment_activity_label: "Sell"
                )
              )

              account.entries.create!(
                date:        date,
                name:        "P2P Receipt (#{fiat_currency})",
                amount:      fiat_amount, # Fiat entering the system
                currency:    fiat_currency,
                external_id: funding_external_id,
                source:      "binance",
                entryable:   Transaction.new
              )
            end
          end
        rescue => e
          Rails.logger.error "BINANCE P2P SYNC CRASHED for Order #{trade["orderNumber"]}: #{e.message}"
          raise
        end
      end
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - P2P trade processing failed: #{e.message}"
      raise
    end

    def commission_in_usd(trade, base_symbol, trade_price, date: nil)
      raw            = trade["commission"].to_d
      commission_asset = trade["commissionAsset"].to_s.upcase
      return 0 if raw.zero? || commission_asset.blank?

      stablecoins = BinanceAccount::STABLECOINS
      return raw if stablecoins.include?(commission_asset)

      # Fee in base asset (e.g. BTC for BTCUSDT) — convert using trade price
      return (raw * trade_price).round(8) if commission_asset == base_symbol

      # Fee in another asset (typically BNB) — fetch current USDT spot price as approximation
      provider = binance_account.binance_item&.binance_provider
      return 0 unless provider

      spot = nil
      spot = provider.get_historical_price("#{commission_asset}USDT", date) if date.present? && provider.respond_to?(:get_historical_price)
      spot ||= provider.get_spot_price("#{commission_asset}USDT")

      (raw * spot.to_d).round(8)
    rescue StandardError => e
      Rails.logger.warn "BinanceAccount::Processor - could not convert commission for #{trade["id"]}: #{e.message}"
      0
    end
end
