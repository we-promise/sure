module TruelayerItem::Provided
  extend ActiveSupport::Concern

  def truelayer_provider
    return nil unless credentials_configured?

    Provider::Truelayer.new(client_id: client_id, client_secret: client_secret)
  end
end
