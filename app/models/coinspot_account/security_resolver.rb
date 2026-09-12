# frozen_string_literal: true

class CoinspotAccount::SecurityResolver
  EXCHANGE_MIC = "XCSO"

  class << self
    # Resolves a CoinSpot asset symbol (e.g. "BTC") to a Security, preferring
    # a real market-data-backed match and falling back to an offline
    # placeholder security when none exists or the resolver errors. Returns
    # nil for fiat currencies and blank symbols, which aren't holdings.
    def resolve(symbol)
      normalized = normalize_symbol(symbol)
      return nil if normalized.blank? || CoinspotAccount::FIAT_CURRENCIES.include?(normalized)

      ticker = "CRYPTO:#{normalized}"
      Security::Resolver.new(ticker).resolve || offline_security!(ticker, normalized)
    rescue StandardError => e
      Rails.logger.warn "CoinspotAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
      offline_security!(ticker, normalized)
    end

    # Uppercases and trims a raw symbol, discarding anything CoinSpot appends
    # after a "|||" separator (seen on some market-order pair identifiers).
    # The blank check has to happen AFTER the suffix is dropped, not before:
    # "|||BTC" is not blank but yields an empty symbol, and "BTC |||AUD"
    # yields "BTC " with a trailing space that would build a bad ticker.
    def normalize_symbol(symbol)
      symbol.to_s.upcase.split("|||", 2).first&.strip.presence
    end

    private

      # Finds or creates a placeholder Security for a symbol with no real
      # market-data match, so holdings can still be recorded against it.
      def offline_security!(ticker, normalized)
        Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |security|
          security.name = normalized if security.name.blank?
          security.offline = true unless security.offline
          security.save! if security.changed?
        end
      end
  end
end
