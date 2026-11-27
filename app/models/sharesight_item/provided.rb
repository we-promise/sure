module SharesightItem::Provided
  extend ActiveSupport::Concern

  def sharesight_provider
    return nil unless credentials_configured?

    Provider::Sharesight.new(client_id: client_id, client_secret: client_secret)
  end
end
