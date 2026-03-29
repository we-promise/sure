# frozen_string_literal: true

# Creates/updates Holdings for each asset in the combined BinanceAccount.
# One Holding per (symbol, source) pair.
class BinanceAccount::HoldingsProcessor
  STABLECOINS = %w[USDT BUSD FDUSD TUSD USDC DAI].freeze

  SOURCE_LABELS = {
    "spot"   => "Spot Wallet",
    "margin" => "Margin",
    "earn"   => "Simple Earn"
  }.freeze

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
  rescue => e
    Rails.logger.error "BinanceAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :binance_account

    def account
      binance_account.current_account
    end

    def raw_assets
      binance_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol  = asset["symbol"] || asset[:symbol]
      total   = (asset["total"] || asset[:total]).to_d
      source  = asset["source"] || asset[:source]

      return if total.zero?

      ticker = symbol.include?(":") ? symbol : "CRYPTO:#{symbol}"
      security = resolve_security(ticker, symbol)
      return unless security

      price  = fetch_price(symbol)
      amount = (total * price).round(2)

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: "USD",
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "binance_#{symbol}_#{source}_#{Date.current}",
        account_provider_id: binance_account.account_provider&.id,
        source: "binance",
        delete_future_holdings: false
      )

      Rails.logger.info "BinanceAccount::HoldingsProcessor - imported #{total} #{symbol} (#{source}) @ #{price}"
    rescue => e
      Rails.logger.error "BinanceAccount::HoldingsProcessor - failed asset #{asset}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(ticker, symbol)
      Security::Resolver.new(ticker).resolve
    rescue => e
      Rails.logger.warn "BinanceAccount::HoldingsProcessor - resolver failed for #{ticker}: #{e.message}"
      Security.find_or_initialize_by(ticker: ticker).tap do |sec|
        sec.offline = true if sec.respond_to?(:offline=) && sec.offline != true
        sec.name = symbol if sec.name.blank?
        sec.exchange_operating_mic = "XBNC"
        sec.save! if sec.changed?
      end
    end

    def fetch_price(symbol)
      return 1.0 if STABLECOINS.include?(symbol)

      provider = binance_account.binance_item&.binance_provider
      return 0 unless provider

      price_str = provider.get_spot_price("#{symbol}USDT")

      if price_str.nil?
        Rails.logger.warn "BinanceAccount::HoldingsProcessor - no price returned for #{symbol}"
        return 0
      end

      price_str.to_d
    rescue => e
      Rails.logger.warn "BinanceAccount::HoldingsProcessor - no price for #{symbol}: #{e.message}"
      0
    end
end
