# frozen_string_literal: true

class OnchainWalletAccount::SecurityResolver
  EXCHANGE_MIC = "XOCW"
  BINANCE_PRICE_PROVIDER = "binance_public"

  def self.resolve(symbol, name = nil)
    ticker = "CRYPTO:#{symbol.to_s.upcase}"

    # Bind the bare "CRYPTO:<SYMBOL>" ticker directly to the price provider
    # instead of going through provider search. Binance Public's parse_ticker
    # maps "CRYPTO:BTC" -> BTCUSDT (USD) and treats stablecoins as $1, so this
    # guarantees a USD price. Provider search could otherwise resolve, e.g.,
    # "CRYPTO:BTC" to a BTCBRL pair, requiring a fragile FX conversion.
    binance = Setting.enabled_securities_providers.include?(BINANCE_PRICE_PROVIDER)
    mic = binance ? Provider::BinancePublic::BINANCE_MIC : EXCHANGE_MIC

    # Reuse an existing security for this ticker regardless of its MIC, so the
    # same asset isn't split into two Security records (which would break
    # historical-holding/trade continuity) when the active provider changes.
    security = Security.find_by(ticker: ticker) ||
      Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: mic)
    security.name = name.presence || symbol.to_s.upcase if security.name.blank?

    if binance
      security.price_provider = BINANCE_PRICE_PROVIDER if security.price_provider.blank?
      security.offline = false if security.offline != false
    elsif security.new_record?
      security.offline = true
    end

    security.save! if security.changed?
    security
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    Rails.logger.warn "OnchainWalletAccount::SecurityResolver - resolver failed for #{symbol}: #{e.message}"
    nil
  end
end
