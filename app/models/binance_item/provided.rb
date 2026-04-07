module BinanceItem::Provided
  extend ActiveSupport::Concern

  def binance_provider
    return nil unless credentials_configured?

    Provider::Binance.new(api_key: api_key, api_secret: api_secret)
  end
end
