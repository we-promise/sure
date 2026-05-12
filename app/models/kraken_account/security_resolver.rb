# frozen_string_literal: true

class KrakenAccount::SecurityResolver
  EXCHANGE_MIC = "XKRA"

  def self.resolve(ticker, symbol)
    Security::Resolver.new(ticker).resolve
  rescue StandardError => e
    Rails.logger.warn "KrakenAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
    Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |security|
      security.name = symbol if security.name.blank?
      security.offline = true unless security.offline
      security.save! if security.changed?
    end
  end
end
