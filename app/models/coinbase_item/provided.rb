module CoinbaseItem::Provided
  extend ActiveSupport::Concern

  def coinbase_provider
    return nil unless credentials_configured?

    Provider::Coinbase.new(api_key: api_key, api_secret: api_secret)
  end
end
