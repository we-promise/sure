# frozen_string_literal: true

class KrakenAccount::Processor
  include KrakenAccount::UsdConverter

  attr_reader :kraken_account

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless kraken_account.current_account.present?

    KrakenAccount::HoldingsProcessor.new(kraken_account).process
    process_account!
    process_trades
  end

  private

    def target_currency
      kraken_account.kraken_item&.family&.currency
    end

    def process_account!
      account = kraken_account.current_account
      amount, stale, rate_date = convert_from_usd((kraken_account.current_balance || 0).to_d, date: Date.current)

      account.update!(
        balance: amount,
        cash_balance: 0,
        currency: target_currency
      )

      kraken_account.update!(extra: kraken_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    end

    def process_trades
      raw_trades.each do |txid, trade|
        process_trade(txid, trade)
      end
    rescue StandardError => e
      Rails.logger.error "KrakenAccount::Processor - trade processing failed: #{e.message}"
    end

    def raw_trades
      kraken_account.raw_transactions_payload&.dig("trades") || {}
    end

    def process_trade(txid, trade)
      account = kraken_account.current_account
      return unless account

      external_id = "kraken_trade_#{txid}"
      return if account.entries.exists?(external_id: external_id, source: "kraken")

      type = trade["type"].to_s.downcase
      return unless %w[buy sell].include?(type)

      pair = trade["pair"].to_s
      base_symbol, quote_symbol = infer_pair_symbols(pair, trade)
      return if base_symbol.blank?

      qty = trade["vol"].to_d
      return if qty.zero?

      price = trade["price"].to_d
      cost = trade["cost"].presence&.to_d
      cost ||= (qty * price).round(8)
      fee = trade["fee"].presence&.to_d || 0
      currency = quote_symbol.presence || "USD"
      date = Time.zone.at(trade["time"].to_d).to_date
      security = KrakenAccount::SecurityResolver.resolve("CRYPTO:#{base_symbol}", base_symbol)
      return unless security

      entry_amount = type == "buy" ? -cost : cost
      trade_qty = type == "buy" ? qty : -qty
      label = type == "buy" ? "Buy" : "Sell"

      account.entries.create!(
        date: date,
        name: "#{label} #{qty.round(8)} #{base_symbol}",
        amount: entry_amount,
        currency: currency,
        external_id: external_id,
        source: "kraken",
        notes: trade["ordertxid"].presence,
        entryable: Trade.new(
          security: security,
          qty: trade_qty,
          price: price,
          currency: currency,
          fee: fee,
          investment_activity_label: label
        )
      )
    rescue StandardError => e
      Rails.logger.error "KrakenAccount::Processor - failed to process trade #{txid}: #{e.message}"
    end

    def infer_pair_symbols(pair, trade)
      pair_metadata = kraken_account.raw_payload&.dig("pair_metadata") || {}
      metadata = pair_metadata[pair] || pair_metadata.values.find { |candidate| candidate["altname"].to_s == pair }
      normalizer = KrakenAccount::AssetNormalizer.new(kraken_account.raw_payload&.dig("asset_metadata") || {})

      if metadata
        base = normalizer.normalize(metadata["base"])[:symbol]
        quote = normalizer.normalize(metadata["quote"])[:symbol]
        return [ base, quote ]
      end

      altname = trade["pair"].to_s
      %w[USDT USDC USD EUR GBP BTC ETH].each do |quote|
        next unless altname.end_with?(quote)

        return [ normalizer.normalize(altname.delete_suffix(quote))[:symbol], quote ]
      end

      [ altname, "USD" ]
    end
end
