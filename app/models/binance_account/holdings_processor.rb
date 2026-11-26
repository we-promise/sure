# frozen_string_literal: true

# Creates/updates Holdings for each asset in the combined BinanceAccount.
# One Holding per symbol: an asset held in several wallets shares one security,
# and holdings are unique per security and day.
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

    positions = aggregate_positions(assets)
    positions.each { |position| process_position(position) }
    cleanup_stale_holdings!(positions)
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
    # imported: an asset whose security could not be resolved is skipped above,
    # and deleting it would turn that failure into a disappeared holding.
    def cleanup_stale_holdings!(positions)
      provider_id = binance_account.account_provider&.id
      return if provider_id.nil?

      keep = positions.map { |position| holding_external_id(position[:symbol], position[:sources]) }
      scope = account.holdings.where(account_provider_id: provider_id, date: Date.current)
      scope = scope.where.not(external_id: keep) if keep.any?

      removed = scope.delete_all
      Rails.logger.info "BinanceAccount::HoldingsProcessor - removed #{removed} holding(s) no longer in the wallet" if removed.positive?
    end

    # A single wallet keeps its historical id, so existing rows still match.
    def holding_external_id(symbol, sources)
      "binance_#{symbol}_#{Array(sources).join('+')}_#{Date.current}"
    end

    def aggregate_positions(assets)
      assets.each_with_object({}) do |asset, positions|
        symbol = asset["symbol"] || asset[:symbol]
        total = (asset["total"] || asset[:total]).to_d
        next if symbol.blank? || total.zero?

        position = positions[symbol] ||= { symbol: symbol, total: 0.to_d, sources: [] }
        position[:total] += total
        position[:sources] |= [ (asset["source"] || asset[:source]).to_s ]
      end.values.each { |position| position[:sources].sort! }
    end

    def process_position(position)
      symbol = position[:symbol]
      total = position[:total]
      source = position[:sources].join("+")

      ticker   = symbol.include?(":") ? symbol : "CRYPTO:#{symbol}"
      security = resolve_security(ticker, symbol)
      return unless security

      quote = quote_for(symbol, security)
      price_usd = quote&.dig("price_usd").to_d
      unless quote && quote["date"] == Date.current.iso8601
        # An unavailable quote does not mean the reported units disappeared.
        # Keep the quantity so reverse reconstruction cannot invent a short.
        DebugLogEntry.capture(
          category: "provider_sync", level: "warn",
          message: "Binance holding has no current market price",
          source: self.class.name, provider_key: "binance",
          family: account.family, account_provider: binance_account.account_provider,
          metadata: { symbol: symbol, quantity: total.to_s("F"), wallet: source, quote_date: quote&.dig("date") }
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
        external_id:            holding_external_id(symbol, position[:sources]),
        account_provider_id:    binance_account.account_provider&.id,
        source:                 "binance",
        delete_future_holdings: false
      )

      Rails.logger.info "BinanceAccount::HoldingsProcessor - imported #{total} #{symbol} (#{source}) @ #{price_usd} USD → #{amount} #{target_currency}"
    rescue StandardError => e
      Rails.logger.error "BinanceAccount::HoldingsProcessor - failed asset #{position}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # The importer stores the quotes it valued the account total with; using
    # them keeps holdings consistent with that total. A symbol missing from
    # them had no quote at all. Payloads written before quotes were stored are
    # priced here instead.
    def quote_for(symbol, security)
      quotes = binance_account.raw_payload&.dig("quotes")
      return quotes[symbol] if quotes.is_a?(Hash)

      pricer.quote(symbol, security: security)
    end

    def pricer
      @pricer ||= BinanceAccount::AssetPricer.new(binance_account.binance_item&.binance_provider)
    end

    def resolve_security(ticker, symbol)
      BinanceAccount::SecurityResolver.resolve(ticker, symbol)
    end
end
