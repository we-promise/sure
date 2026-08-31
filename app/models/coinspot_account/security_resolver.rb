# frozen_string_literal: true

class CoinspotAccount::SecurityResolver
  EXCHANGE_MIC = "XCSO"

  class << self
    def resolve(symbol)
      normalized = normalize_symbol(symbol)
      return nil if normalized.blank? || CoinspotAccount::FIAT_CURRENCIES.include?(normalized)

      ticker = "CRYPTO:#{normalized}"
      Security::Resolver.new(ticker).resolve || offline_security!(ticker, normalized)
    rescue StandardError => e
      Rails.logger.warn "CoinspotAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
      offline_security!(ticker, normalized)
    end

    def normalize_symbol(symbol)
      value = symbol.to_s.strip.upcase
      return nil if value.blank?

      value.split("|||").first
    end

    private

      def offline_security!(ticker, normalized)
        Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |security|
          security.name = normalized if security.name.blank?
          security.offline = true unless security.offline
          security.save! if security.changed?
        end
      end
  end
end
