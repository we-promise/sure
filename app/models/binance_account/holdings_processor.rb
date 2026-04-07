# frozen_string_literal: true

# Creates/updates Holdings for each asset in the combined BinanceAccount.
# One Holding per (symbol, source) pair.
class BinanceAccount::HoldingsProcessor
  include BinanceAccount::UsdConverter

  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    unless account&.accountable_type == "Crypto"
      Rails.logger.info "BinanceAccount::HoldingsProcessor - skipping: not a Crypto account"
      return
    end

    assets = raw_assets
    if assets.empty?
      Rails.logger.info "BinanceAccount::HoldingsProcessor - no assets in payload"
      return
    end

    assets.each { |asset| process_asset(asset) }
  rescue StandardError => e
    Rails.logger.error "BinanceAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :binance_account

    def target_currency
      binance_account.binance_item.family.currency
    end

    def account
      binance_account.current_account
    end

    def raw_assets
      binance_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      return if symbol.blank?

      total  = (asset["total"] || asset[:total]).to_d
      source = asset["source"] || asset[:source]

      return if total.zero?

      ticker   = symbol.include?(":") ? symbol : "CRYPTO:#{symbol}"
      security = resolve_security(ticker, symbol)
      return unless security

      price_usd = fetch_price(symbol)
      return if price_usd.nil?

      amount_usd = total * price_usd

      # Stale rate metadata is intentionally discarded here — it is captured and
      # surfaced at the account level by BinanceAccount::Processor#process_account!.
      amount, _stale, _rate_date = convert_from_usd(amount_usd, date: Date.current)

      # Also convert per-unit price to target currency
      price, _, _ = convert_from_usd(price_usd, date: Date.current)

      import_adapter.import_holding(
        security:               security,
        quantity:               total,
        amount:                 amount,
        currency:               target_currency,
        date:                   Date.current,
        price:                  price,
        cost_basis:             nil,
        external_id:            "binance_#{symbol}_#{source}_#{Date.current}",
        account_provider_id:    binance_account.account_provider&.id,
        source:                 "binance",
        delete_future_holdings: false
      )

      Rails.logger.info "BinanceAccount::HoldingsProcessor - imported #{total} #{symbol} (#{source}) @ #{price_usd} USD → #{amount} #{target_currency}"
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::HoldingsProcessor - failed asset #{asset}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(ticker, symbol)
      BinanceAccount::SecurityResolver.resolve(ticker, symbol)
    end

    def fetch_price(symbol)
      return 1.0 if BinanceAccount::STABLECOINS.include?(symbol)

      provider = binance_account.binance_item&.binance_provider
      return nil unless provider

      %w[USDT BUSD FDUSD].each do |quote|
        price_str = provider.get_spot_price("#{symbol}#{quote}")
        return price_str.to_d if price_str.present?
      end

      Rails.logger.warn "BinanceAccount::HoldingsProcessor - no price found for #{symbol} across all quote pairs; skipping holding"
      nil
    end
end
