module UpItem::Provided
  extend ActiveSupport::Concern

  def up_provider
    return nil unless credentials_configured?

    Provider::Up.new(access_token)
  end

  def syncer
    UpItem::Syncer.new(self)
  end
end
