module KrakenItem::Provided
  extend ActiveSupport::Concern

  def kraken_provider
    return nil unless credentials_configured?

    Provider::Kraken.new(api_key: api_key, api_secret: api_secret)
  end
end
