module AkahuItem::Provided
  extend ActiveSupport::Concern

  def akahu_provider
    return nil unless credentials_configured?

    Provider::Akahu.new(
      app_token: app_token,
      user_token: user_token
    )
  end

  def syncer
    AkahuItem::Syncer.new(self)
  end
end
