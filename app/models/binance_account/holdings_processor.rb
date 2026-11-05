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
    if assets.nil?
      # No asset list at all is not an empty wallet, it is a wallet nothing has
      # reported on yet. Cleaning up here would delete holdings on the strength
      # of missing information.
      Rails.logger.info "BinanceAccount::HoldingsProcessor - no asset list in payload"
      return
    end

    assets.each { |asset| process_asset(asset) }
    cleanup_stale_holdings!(assets)
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

    # nil when the payload has never carried an asset list, [] when Binance
    # reported an empty wallet. The two mean different things to the cleanup.
    def raw_assets
      binance_account.raw_payload&.dig("assets")
    end

    # Binance reports what the wallet holds NOW, so a holding written for today
    # whose asset is no longer in the payload is one that has left the wallet.
    # Nothing removed them before, and the account page reads exactly today's
    # rows — so a coin sold hours ago was still in the portfolio.
    #
    # Keyed on what the PAYLOAD contains, not on what was successfully
    # imported: an asset whose price could not be fetched is skipped above, and
    # deleting it would turn a price outage into a disappeared holding.
    def cleanup_stale_holdings!(assets)
      provider_id = binance_account.account_provider&.id
      return if provider_id.nil?

      keep = assets.filter_map { |asset| external_id_for(asset) }
      scope = account.holdings.where(account_provider_id: provider_id, date: Date.current)
      scope = scope.where.not(external_id: keep) if keep.any?

      removed = scope.delete_all
      Rails.logger.info "BinanceAccount::HoldingsProcessor - removed #{removed} holding(s) no longer in the wallet" if removed.positive?
    end

    def external_id_for(asset)
      symbol = asset["symbol"] || asset[:symbol]
      source = asset["source"] || asset[:source]
      return if symbol.blank?
      return if (asset["total"] || asset[:total]).to_d.zero?

      holding_external_id(symbol, source)
    end

    def holding_external_id(symbol, source)
      "binance_#{symbol}_#{source}_#{Date.current}"
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
      if price_usd.nil?
        # An unavailable quote does not mean the reported units disappeared.
        # Keep the quantity so reverse reconstruction cannot invent a short.
        price_usd = cached_price_usd(security) || 0.to_d
        DebugLogEntry.capture(
          category: "provider_sync", level: "warn",
          message: "Binance holding has no available market price",
          source: self.class.name, provider_key: "binance",
          family: account.family, account_provider: binance_account.account_provider,
          metadata: { symbol: symbol, quantity: total.to_s("F"), wallet: source }
        )
      end

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
        external_id:            holding_external_id(symbol, source),
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

    def cached_price_usd(security)
      quote = security.prices.where("price > 0 AND date <= ?", Date.current).order(date: :desc).first
      quote ||= account.holdings.where(security: security).where("price > 0 AND date <= ?", Date.current).order(date: :desc).first
      return unless quote

      Money.new(quote.price, quote.currency).exchange_to("USD", date: quote.date).amount
    rescue Money::ConversionError, Money::Currency::UnknownCurrencyError
      nil
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

      Rails.logger.warn "BinanceAccount::HoldingsProcessor - no price found for #{symbol} across all quote pairs"
      nil
    end
end
