module Trading212Item::Provided
  extend ActiveSupport::Concern

  def trading212_provider
    return nil unless credentials_configured?

    Provider::Trading212.new(api_key: api_key, api_secret: api_secret, environment: environment)
  end
end
