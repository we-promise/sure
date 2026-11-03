module EtoroItem::Provided
  extend ActiveSupport::Concern

  def etoro_provider
    return nil unless credentials_configured?

    Provider::Etoro.new(api_key: api_key, user_key: user_key)
  end
end
