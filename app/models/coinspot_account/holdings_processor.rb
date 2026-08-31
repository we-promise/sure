# frozen_string_literal: true

class CoinspotAccount::HoldingsProcessor
  include CoinspotAccount::AudConverter

  def initialize(coinspot_account)
    @coinspot_account = coinspot_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    raw_assets.each { |asset| process_asset(asset) }
  rescue StandardError => e
    Rails.logger.error "CoinspotAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :coinspot_account

    def target_currency
      coinspot_account.coinspot_item&.family&.currency
    end

    def account
      coinspot_account.current_account
    end

    def raw_assets
      coinspot_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      return if symbol.to_s.upcase == "AUD"

      total = (asset["balance"] || asset[:balance] || 0).to_d
      amount_aud = asset["amount_aud"] || asset[:amount_aud]
      price_aud = asset["price_aud"] || asset[:price_aud]
      source = asset["source"] || asset[:source] || "spot"

      return if symbol.blank? || total.zero? || amount_aud.blank?

      security = CoinspotAccount::SecurityResolver.resolve(symbol)
      return unless security

      amount, amount_stale, amount_rate_date = convert_from_aud(amount_aud.to_d, date: Date.current)
      price = if price_aud.present?
        converted_price, price_stale, price_rate_date = convert_from_aud(price_aud.to_d, date: Date.current)
        log_stale_rate(symbol, "price", price_rate_date) if price_stale
        converted_price
      end
      log_stale_rate(symbol, "amount", amount_rate_date) if amount_stale

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: target_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "coinspot_#{symbol}_#{source}_#{Date.current}",
        account_provider_id: coinspot_account.account_provider&.id,
        source: "coinspot",
        delete_future_holdings: false
      )
    rescue StandardError => e
      Rails.logger.error "CoinspotAccount::HoldingsProcessor - failed asset symbol=#{symbol.presence || "unknown"}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def log_stale_rate(symbol, field, rate_date)
      Rails.logger.warn(
        "CoinspotAccount::HoldingsProcessor - stale FX rate for #{field} symbol=#{symbol} rate_date=#{rate_date || "unknown"}"
      )
    end
end
