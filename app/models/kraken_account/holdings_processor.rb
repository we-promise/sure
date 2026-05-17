# frozen_string_literal: true

class KrakenAccount::HoldingsProcessor
  include KrakenAccount::UsdConverter

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    raw_assets.each { |asset| process_asset(asset) }
  rescue StandardError => e
    Rails.logger.error "KrakenAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :kraken_account

    def target_currency
      kraken_account.kraken_item&.family&.currency
    end

    def account
      kraken_account.current_account
    end

    def raw_assets
      kraken_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      price_symbol = asset["price_symbol"] || asset[:price_symbol] || symbol
      total = (asset["balance"] || asset[:balance] || 0).to_d
      price_usd = asset["price_usd"] || asset[:price_usd]
      source = asset["source"] || asset[:source] || "spot"

      return if symbol.blank? || total.zero? || price_usd.blank?

      security = resolve_security(symbol)
      return unless security

      amount_usd = total * price_usd.to_d
      amount, amount_stale, amount_rate_date = convert_from_usd(amount_usd, date: Date.current)
      price, price_stale, price_rate_date = convert_from_usd(price_usd.to_d, date: Date.current)
      log_stale_rate(symbol, "amount", amount_rate_date) if amount_stale
      log_stale_rate(symbol, "price", price_rate_date) if price_stale

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: target_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "kraken_#{symbol}_#{source}_#{Date.current}",
        account_provider_id: kraken_account.account_provider&.id,
        source: "kraken",
        delete_future_holdings: false
      )
    rescue StandardError => e
      Rails.logger.error "KrakenAccount::HoldingsProcessor - failed asset symbol=#{symbol.presence || "unknown"}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(symbol)
      ticker = symbol.to_s.include?(":") ? symbol.to_s : "CRYPTO:#{symbol}"
      KrakenAccount::SecurityResolver.resolve(ticker, symbol)
    end

    def log_stale_rate(symbol, field, rate_date)
      Rails.logger.warn(
        "KrakenAccount::HoldingsProcessor - stale FX rate for #{field} symbol=#{symbol} rate_date=#{rate_date || "unknown"}"
      )
    end
end
