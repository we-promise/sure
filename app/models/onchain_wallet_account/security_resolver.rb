# frozen_string_literal: true

class OnchainWalletAccount::SecurityResolver
  EXCHANGE_MIC = "XOCW"
  BINANCE_PRICE_PROVIDER = "binance_public"

  def self.resolve(symbol, name = nil)
    ticker = "CRYPTO:#{symbol.to_s.upcase}"
    Security::Resolver.new(
      ticker,
      **resolver_options
    ).resolve
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    Rails.logger.warn "OnchainWalletAccount::SecurityResolver - resolver failed for #{symbol}: #{e.message}"
    mic = resolver_options[:exchange_operating_mic] || EXCHANGE_MIC
    Security.find_or_initialize_by(ticker: "CRYPTO:#{symbol.to_s.upcase}", exchange_operating_mic: mic).tap do |security|
      security.name = name.presence || symbol.to_s.upcase if security.name.blank?
      security.offline = true unless security.offline
      security.save! if security.changed?
    end
  end

  def self.resolver_options
    return {} unless Setting.enabled_securities_providers.include?(BINANCE_PRICE_PROVIDER)

    {
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      price_provider: BINANCE_PRICE_PROVIDER
    }
  end
  private_class_method :resolver_options
end
