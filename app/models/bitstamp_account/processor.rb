# frozen_string_literal: true

class BitstampAccount::Processor
  attr_reader :bitstamp_account

  def initialize(bitstamp_account)
    @bitstamp_account = bitstamp_account
  end

  def process
    return unless bitstamp_account.current_account.present?

    BitstampAccount::HoldingsProcessor.new(bitstamp_account).process
    process_account!
    process_trades
    process_earn_transactions
    process_deposits
  end

  private

    def target_currency
      bitstamp_account.bitstamp_item&.family&.currency
    end

    def asset_price_usd(symbol)
      assets = bitstamp_account.raw_payload&.dig("assets") || []
      asset = assets.find { |a| a["symbol"].to_s.upcase == symbol.to_s.upcase }
      asset&.dig("price_usd")&.to_d
    end

    def earn_subscription_type(symbol)
      assets = bitstamp_account.raw_payload&.dig("assets") || []
      earn_asset = assets.find { |a| a["symbol"].to_s.upcase == symbol.to_s.upcase && a["source"].to_s == "earn" }
      earn_asset&.dig("subscription_type").to_s.upcase
    end

    def qty_to_usd(symbol, qty, date: Date.current)
      if BitstampAccount::STABLECOINS.include?(symbol)
        qty.abs
      elsif BitstampAccount::FIAT_CURRENCIES.include?(symbol)
        rate = ExchangeRate.find_or_fetch_rate(from: symbol, to: "USD", date: date)
        rate ? (qty.abs * rate.rate.to_d).round(8) : qty.abs
      else
        price = asset_price_usd(symbol)
        price ? (qty.abs * price).round(8) : 0.to_d
      end
    end

    def process_account!
      account = bitstamp_account.current_account
      amount = convert_from_usd((bitstamp_account.current_balance || 0).to_d)

      account.update!(
        balance: amount,
        cash_balance: fiat_cash_balance,
        currency: target_currency
      )

      # Align any valuations created before the account currency was set to target_currency
      account.entries.where(entryable_type: "Valuation").where.not(currency: target_currency).update_all(currency: target_currency)
    end

    def fiat_cash_balance
      assets = bitstamp_account.raw_payload&.dig("assets") || []
      total_usd = assets.sum do |asset|
        symbol = (asset["symbol"] || asset[:symbol]).to_s.upcase
        next 0 unless BitstampAccount::FIAT_CURRENCIES.include?(symbol)

        (asset["amount_usd"] || asset[:amount_usd]).to_d
      end
      convert_from_usd(total_usd)
    end

    def process_trades
      raw_transactions.each do |transaction|
        process_trade(transaction)
      end
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - trade processing failed: #{e.message}"
    end

    def process_earn_transactions
      raw_earn_transactions.each do |transaction|
        process_earn_transaction(transaction)
      end
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - earn transaction processing failed: #{e.message}"
    end

    def process_deposits
      raw_transactions.each do |transaction|
        process_deposit(transaction)
      end
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - deposit processing failed: #{e.message}"
    end

    def raw_transactions
      bitstamp_account.raw_transactions_payload&.dig("transactions") || []
    end

    def raw_earn_transactions
      bitstamp_account.raw_transactions_payload&.dig("earn_transactions") || []
    end

    def process_trade(transaction)
      account = bitstamp_account.current_account
      return unless account

      return unless transaction["type"].to_s == "2"

      txid = transaction["id"].to_s
      external_id = "bitstamp_trade_#{txid}"
      return if account.entries.exists?(external_id: external_id, source: "bitstamp")

      base_symbol, quote_symbol, qty, price, cost, fee = extract_trade_fields(transaction)
      return if base_symbol.blank? || qty.nil? || qty.zero?

      type = qty.positive? ? "buy" : "sell"
      qty_abs = qty.abs
      security = BitstampAccount::SecurityResolver.resolve("CRYPTO:#{base_symbol}", base_symbol)
      return unless security

      date = parse_transaction_date(transaction["datetime"])
      return unless date

      quote_currency = normalize_currency(quote_symbol)
      cost_in_target, price_in_target, fee_in_target = convert_trade_to_target(cost, price, fee, quote_currency, date)

      trade_qty = type == "buy" ? qty_abs : -qty_abs
      entry_amount = type == "buy" ? -cost_in_target.abs : cost_in_target.abs
      label = type == "buy" ? "Buy" : "Sell"

      account.entries.create!(
        date: date,
        name: "#{label} #{qty_abs.round(8)} #{base_symbol}",
        amount: entry_amount,
        currency: target_currency,
        external_id: external_id,
        source: "bitstamp",
        notes: transaction["order_id"].presence,
        entryable: Trade.new(
          security: security,
          qty: trade_qty,
          price: price_in_target,
          currency: target_currency,
          fee: fee_in_target,
          investment_activity_label: label
        )
      )

    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - failed to process trade #{transaction["id"]}: #{e.message}"
    end

    def process_earn_transaction(transaction)
      account = bitstamp_account.current_account
      return unless account

      symbol = transaction["currency"].to_s.upcase
      qty = transaction["amount"].to_d
      reward_type = transaction["type"].to_s.upcase
      return if symbol.blank? || qty.zero?

      datetime_str = transaction["datetime"].to_s
      external_id = "bitstamp_earn_#{symbol}_#{reward_type}_#{datetime_str}"
      return if account.entries.exists?(external_id: external_id, source: "bitstamp")

      date = parse_transaction_date(datetime_str)
      return unless date

      value_usd = transaction["value"].to_d
      amount = -convert_from_usd(value_usd, date: date).abs

      is_staking = earn_subscription_type(symbol) == "STAKING"
      name = is_staking ? "#{symbol} staking reward" : "#{symbol} lending interest"

      entry = account.entries.create!(
        date: date,
        name: name,
        amount: amount,
        currency: target_currency,
        external_id: external_id,
        source: "bitstamp",
        entryable: Transaction.new(investment_activity_label: "Interest")
      )
      entry.entryable.set_category!("Interest")
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - failed to process earn transaction #{symbol}: #{e.message}"
    end

    def process_deposit(transaction)
      account = bitstamp_account.current_account
      return unless account

      type_str = transaction["type"].to_s
      return unless %w[0 1].include?(type_str)

      txid = transaction["id"].to_s
      external_id = "bitstamp_deposit_#{txid}"
      return if account.entries.exists?(external_id: external_id, source: "bitstamp")

      symbol, qty = extract_earn_fields(transaction)
      return if symbol.blank? || qty.nil? || qty.zero?

      date = parse_transaction_date(transaction["datetime"])
      return unless date

      is_deposit = type_str == "0"
      label = is_deposit ? "Contribution" : "Withdrawal"

      name = is_deposit ? "#{symbol} deposit" : "#{symbol} withdrawal"
      amount_in_target = convert_from_usd(qty_to_usd(symbol, qty, date: date), date: date)
      amount = is_deposit ? -amount_in_target.abs : amount_in_target.abs

      entry = account.entries.create!(
        date: date,
        name: name,
        amount: amount,
        currency: target_currency,
        external_id: external_id,
        source: "bitstamp",
        entryable: Transaction.new(investment_activity_label: label)
      )
      entry.entryable.set_category!("Investment Contributions") if is_deposit
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::Processor - failed to process deposit #{transaction["id"]}: #{e.message}"
    end

    def extract_earn_fields(transaction)
      excluded = %w[id datetime type fee order_id usd_usd btc_usd]
      keys = transaction.keys.reject { |k| excluded.include?(k) || k.include?("_") }
      key = keys.find { |k| transaction[k].to_d.positive? }
      return [ nil, nil ] unless key

      [ key.upcase, transaction[key].to_d ]
    end

    def extract_trade_fields(transaction)
      currency_keys = transaction.keys.reject { |k| %w[id datetime type fee order_id usd_usd].include?(k) }

      # The pair price key (e.g. "xrp_eur", "usdc_eur") is authoritative for base/quote order.
      pair_key = currency_keys.find { |k| k.include?("_") }
      if pair_key
        base_key, quote_key = pair_key.split("_", 2)
        quote_key = "usd" if quote_key.blank?
      else
        base_key = currency_keys.find { |k| !k.include?("_") && k != "usd" && transaction[k].to_d.nonzero? }
        quote_key = "usd"
      end

      return [ nil, nil, nil, nil, nil, nil ] if base_key.nil?

      base_symbol = base_key.upcase
      quote_symbol = quote_key.upcase

      qty = transaction[base_key].to_d
      cost = transaction[quote_key].to_d
      price = pair_key ? transaction[pair_key].to_d : 0.to_d
      price = (cost.abs / qty.abs).round(8) if price.zero? && qty.nonzero?
      fee = transaction["fee"].to_d

      [ base_symbol, quote_symbol, qty, price, cost, fee ]
    end

    def parse_transaction_date(datetime_str)
      Time.zone.parse(datetime_str.to_s).to_date
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_currency(symbol)
      return "USD" if symbol.blank?
      return "USD" if %w[USDC USDT BUSD DAI TUSD USDP GUSD].include?(symbol)
      Money::Currency.all[symbol.downcase] ? symbol : "USD"
    end

    def convert_trade_to_target(cost, price, fee, quote_currency, date)
      return [ cost, price, fee ] if quote_currency == target_currency

      rate = ExchangeRate.find_or_fetch_rate(from: quote_currency, to: target_currency, date: date)
      return [ cost, price, fee ] if rate.nil?

      multiplier = rate.rate.to_d
      [
        (cost * multiplier).round(8),
        (price * multiplier).round(8),
        (fee * multiplier).round(8)
      ]
    end

    def convert_from_usd(amount, date: Date.current)
      return amount.to_d if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)
      return amount.to_d if rate.nil?

      Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
    end
end
