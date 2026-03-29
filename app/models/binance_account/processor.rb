# frozen_string_literal: true

# Updates account balance and imports spot trades.
class BinanceAccount::Processor
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
    rescue => e
      Rails.logger.error "BinanceAccount::Processor - holdings failed for #{binance_account.id}: #{e.message}"
    end

    begin
      process_account!
    rescue => e
      Rails.logger.error "BinanceAccount::Processor - account update failed for #{binance_account.id}: #{e.message}"
      raise
    end

    fetch_and_process_trades
  end

  private

    def process_account!
      account = binance_account.current_account
      balance = binance_account.current_balance.to_d

      account.update!(
        balance: balance,
        cash_balance: 0,
        currency: "USD"
      )
    end

    def fetch_and_process_trades
      provider = binance_account.binance_item&.binance_provider
      return unless provider

      symbols = extract_trade_symbols
      return if symbols.empty?

      trades_by_symbol = {}
      symbols.each do |symbol|
        pair = "#{symbol}USDT"
        begin
          trades = provider.get_spot_trades(pair)
          trades_by_symbol[pair] = trades if trades.present?
        rescue => e
          Rails.logger.warn "BinanceAccount::Processor - could not fetch trades for #{pair}: #{e.message}"
        end
      end

      binance_account.update!(raw_transactions_payload: {
        "spot" => trades_by_symbol,
        "fetched_at" => Time.current.iso8601
      })

      process_trades(trades_by_symbol)
    end

    def extract_trade_symbols
      assets = binance_account.raw_payload&.dig("assets") || []
      assets
        .map { |a| a["symbol"] || a[:symbol] }
        .uniq
        .reject { |s| BinanceAccount::HoldingsProcessor::STABLECOINS.include?(s) }
    end

    def process_trades(trades_by_symbol)
      spot = trades_by_symbol["spot"] || {}
      spot.each do |pair, trades|
        trades.each { |trade| process_spot_trade(trade, pair) }
      end
    rescue => e
      Rails.logger.error "BinanceAccount::Processor - trade processing failed: #{e.message}"
    end

    def process_spot_trade(trade, pair)
      account = binance_account.current_account
      return unless account

      base_symbol = pair.gsub(/USDT$|BUSD$|FDUSD$/, "")
      return if base_symbol.blank?

      ticker = "CRYPTO:#{base_symbol}"
      security = begin
        Security::Resolver.new(ticker).resolve
      rescue
        Security.find_or_create_by(ticker: ticker) do |s|
          s.name = base_symbol
          s.exchange_operating_mic = "XBNC"
          s.offline = true if s.respond_to?(:offline=)
        end
      end

      return unless security

      external_id = "binance_spot_#{trade["id"]}"
      return if account.entries.exists?(external_id: external_id)

      date      = Time.zone.at(trade["time"].to_i / 1000).to_date
      qty       = trade["qty"].to_d
      price     = trade["price"].to_d
      total_usd = (qty * price).round(2)
      is_buyer  = trade["isBuyer"]

      if is_buyer
        account.entries.create!(
          date: date,
          name: "Buy #{qty.round(8)} #{base_symbol}",
          amount: -total_usd,
          currency: "USD",
          external_id: external_id,
          source: "binance",
          entryable: Trade.new(
            security: security,
            qty: qty,
            price: price,
            currency: "USD",
            investment_activity_label: "Buy"
          )
        )
      else
        account.entries.create!(
          date: date,
          name: "Sell #{qty.round(8)} #{base_symbol}",
          amount: total_usd,
          currency: "USD",
          external_id: external_id,
          source: "binance",
          entryable: Trade.new(
            security: security,
            qty: -qty,
            price: price,
            currency: "USD",
            investment_activity_label: "Sell"
          )
        )
      end
    rescue => e
      Rails.logger.error "BinanceAccount::Processor - failed to process trade #{trade["id"]}: #{e.message}"
    end
end
