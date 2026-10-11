# frozen_string_literal: true

class BitstampAccount::HoldingsProcessor
  def initialize(bitstamp_account)
    @bitstamp_account = bitstamp_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    raw_assets.each { |asset| process_asset(asset) }
  rescue StandardError => e
    Rails.logger.error "BitstampAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :bitstamp_account

    def target_currency
      bitstamp_account.bitstamp_item&.family&.currency
    end

    def account
      bitstamp_account.current_account
    end

    def raw_assets
      bitstamp_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      total = (asset["balance"] || asset[:balance] || 0).to_d
      price_usd = asset["price_usd"] || asset[:price_usd]
      source = asset["source"] || asset[:source] || "spot"

      return if symbol.blank? || total.zero? || price_usd.blank?

      # Fiat currencies are cash — handled as cash_balance, not holdings
      return if BitstampAccount::FIAT_CURRENCIES.include?(symbol)

      security = resolve_security(symbol)
      return unless security

      amount_usd = total * price_usd.to_d
      amount, amount_stale, _rate_date = convert_from_usd(amount_usd)
      price, price_stale, _price_rate_date = convert_from_usd(price_usd.to_d)

      return if (amount_stale || price_stale) && target_currency != "USD"

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: target_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "bitstamp_#{symbol}_#{source}_#{Date.current}",
        account_provider_id: bitstamp_account.account_provider&.id,
        source: "bitstamp",
        delete_future_holdings: false
      )
    rescue StandardError => e
      Rails.logger.error "BitstampAccount::HoldingsProcessor - failed asset symbol=#{symbol.presence || "unknown"}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(symbol)
      ticker = symbol.to_s.include?(":") ? symbol.to_s : "CRYPTO:#{symbol}"
      BitstampAccount::SecurityResolver.resolve(ticker, symbol)
    end

    def convert_from_usd(amount)
      return [ amount.to_d, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: Date.current)
      return [ amount.to_d, true, nil ] if rate.nil?

      converted = Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
      stale = rate.date != Date.current
      [ converted, stale, stale ? rate.date : nil ]
    end
end
