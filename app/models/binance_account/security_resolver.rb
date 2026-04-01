# frozen_string_literal: true

# Resolves or creates a Security for a given Binance ticker.
# First attempts Security::Resolver; on failure, falls back to find_or_initialize_by
# and saves an offline security so syncs are not blocked by provider outages.
class BinanceAccount::SecurityResolver
  EXCHANGE_MIC = "XBNC"

  def self.resolve(ticker, symbol)
    result = Security::Resolver.new(ticker).resolve
    if result.nil?
      Rails.logger.debug "BinanceAccount::SecurityResolver - primary resolver returned nil for #{ticker}"
    end
    result
  rescue StandardError => e
    Rails.logger.warn "BinanceAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
    Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |sec|
      sec.name = symbol if sec.name.blank?
      sec.offline = true unless sec.offline
      sec.save! if sec.changed?
    end
  end
end
