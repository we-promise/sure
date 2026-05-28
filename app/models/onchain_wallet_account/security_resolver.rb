# frozen_string_literal: true

class OnchainWalletAccount::SecurityResolver
  EXCHANGE_MIC = "XOCW"

  def self.resolve(symbol, name = nil)
    ticker = "CRYPTO:#{symbol.to_s.upcase}"
    Security::Resolver.new(ticker).resolve
  rescue StandardError => e
    Rails.logger.warn "OnchainWalletAccount::SecurityResolver - resolver failed for #{symbol}: #{e.message}"
    Security.find_or_initialize_by(ticker: "CRYPTO:#{symbol.to_s.upcase}", exchange_operating_mic: EXCHANGE_MIC).tap do |security|
      security.name = name.presence || symbol.to_s.upcase if security.name.blank?
      security.offline = true unless security.offline
      security.save! if security.changed?
    end
  end
end
