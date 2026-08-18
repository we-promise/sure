# frozen_string_literal: true

# Maps an on-chain asset symbol onto a Security.
#
# The ticker is bound straight to the crypto price provider instead of going
# through Security::Resolver's provider search: a search for "USDC" can come
# back as a EUR- or TRY-quoted pair, which would silently value the holding in
# the wrong currency and then need FX to repair. A "CRYPTO:<SYMBOL>" ticker is
# understood by the crypto provider as the USD-quoted asset, full stop.
class Onchain::SecurityResolver
  TICKER_PREFIX = "CRYPTO:"

  # The only securities provider that prices bare crypto symbols.
  PRICE_PROVIDER = "binance_public"
  EXCHANGE_MIC = Provider::BinancePublic::BINANCE_MIC

  # Tickers we are willing to create. Spam airdrops routinely use their symbol
  # as an advertisement ("Visit site to claim", emoji, URLs); those resolve to
  # nil rather than polluting the securities table.
  SYMBOL_PATTERN = /\A[A-Z0-9][A-Z0-9.\-]{0,11}\z/

  class << self
    # @return [Security, nil] nil when the symbol cannot be a ticker
    def resolve(symbol:, name: nil)
      new(symbol: symbol, name: name).resolve
    end

    # Whether this symbol resolves to something the price provider can quote.
    # Used to decide which detected tokens are pre-checked for import.
    def priceable?(symbol)
      new(symbol: symbol).ticker_symbol.present?
    end
  end

  def initialize(symbol:, name: nil)
    @symbol = symbol
    @name = name
  end

  def resolve
    return nil if ticker_symbol.blank?

    existing_security || create_security
  end

  # The canonical symbol this asset is tracked under, or nil when unusable.
  def ticker_symbol
    return @ticker_symbol if defined?(@ticker_symbol)

    candidate = symbol.to_s.strip.upcase
    @ticker_symbol = SYMBOL_PATTERN.match?(candidate) ? candidate : nil
  end

  private
    attr_reader :symbol, :name

    def ticker
      "#{TICKER_PREFIX}#{ticker_symbol}"
    end

    # Deliberately ignores exchange_operating_mic. A Security for this ticker may
    # already exist under another MIC (an exchange provider created it first);
    # reusing it keeps one asset in one record instead of splitting holdings
    # across two rows for the same coin.
    def existing_security
      Security.find_by(ticker: ticker)
    end

    def create_security
      Security.create!(
        ticker: ticker,
        name: name.presence || ticker_symbol,
        exchange_operating_mic: EXCHANGE_MIC,
        price_provider: PRICE_PROVIDER
      )
    end
end
