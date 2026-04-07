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

      symbols = extract_trade_symbols
      return if symbols.empty?

      existing_spot = binance_account.raw_transactions_payload&.dig("spot") || {}
      new_trades_by_symbol = {}

      symbols.each do |symbol|
        TRADE_QUOTE_CURRENCIES.each do |quote|
          pair = "#{symbol}#{quote}"
          begin
            new_trades = fetch_new_trades(provider, pair, existing_spot[pair])
            new_trades_by_symbol[pair] = new_trades if new_trades.present?
          rescue Provider::Binance::InvalidSymbolError => e
            # Pair doesn't exist on Binance for this quote currency — expected, skip silently
            Rails.logger.debug "BinanceAccount::Processor - skipping #{pair}: #{e.message}"
          end
          # ApiError, AuthenticationError and RateLimitError propagate so the sync is marked failed
        end
      end

      merged_spot = existing_spot.merge(new_trades_by_symbol) { |_pair, old, new_t| old + new_t }
      binance_account.update!(raw_transactions_payload: {
        "spot"       => merged_spot,
        "fetched_at" => Time.current.iso8601
      })

      process_trades(new_trades_by_symbol)
    end

    # Fetches only trades newer than what is already cached for the given pair.
    # On the first sync (no cached trades) fetches the most recent page.
    # On subsequent syncs starts from max_cached_id + 1 and paginates forward.
    def fetch_new_trades(provider, pair, cached_trades)
      limit = 1000
      max_cached_id = cached_trades&.map { |t| t["id"].to_i }&.max

      from_id = max_cached_id ? max_cached_id + 1 : nil
      all_new = []

      loop do
        page = provider.get_spot_trades(pair, limit: limit, from_id: from_id)
        break if page.blank?

        all_new.concat(page)
        break if page.size < limit

        from_id = page.map { |t| t["id"].to_i }.max + 1
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
      prev_pairs = binance_account.raw_transactions_payload&.dig("spot")&.keys || []
      previous   = prev_pairs.map { |pair| pair.gsub(quote_re, "") }

      (current + previous).uniq.compact.reject { |s| s.blank? || stablecoins.include?(s) }
    end

    def process_trades(trades_by_symbol)
      trades_by_symbol.each do |pair, trades|
        trades.each { |trade| process_spot_trade(trade, pair) }
      end
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::Processor - trade processing failed: #{e.message}"
    end

    def process_spot_trade(trade, pair)
      account = binance_account.current_account
      return unless account

      quote_suffix = TRADE_QUOTE_CURRENCIES.find { |q| pair.end_with?(q) }
      base_symbol  = quote_suffix ? pair.delete_suffix(quote_suffix) : pair
      return if base_symbol.blank?

      ticker   = "CRYPTO:#{base_symbol}"
      security = BinanceAccount::SecurityResolver.resolve(ticker, base_symbol)

      return unless security

      external_id = "binance_spot_#{pair}_#{trade["id"]}"
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
      is_buyer     = trade["isBuyer"]

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
    end

    # Converts an amount denominated in quote_symbol to USD.
    # Stablecoins are treated as 1:1; others use historical price when date is given,
    # falling back to current USDT spot price.
    def quote_to_usd(amount, quote_symbol, date: nil)
      return amount if BinanceAccount::STABLECOINS.include?(quote_symbol)

      provider = binance_account.binance_item&.binance_provider
      return nil unless provider

      spot = nil
      spot = provider.get_historical_price("#{quote_symbol}USDT", date) if date.present? && provider.respond_to?(:get_historical_price)
      spot ||= provider.get_spot_price("#{quote_symbol}USDT")
      return nil if spot.nil?

      (amount * spot.to_d).round(8)
    rescue StandardError => e
      Rails.logger.warn "BinanceAccount::Processor - could not convert #{quote_symbol} to USD: #{e.message}"
      nil
    end

    # Converts the trade commission to USD.
    # commissionAsset can be: a stablecoin (≈ 1 USD), the base asset, or something else (e.g. BNB).
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
