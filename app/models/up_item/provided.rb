module UpItem::Provided
  extend ActiveSupport::Concern

  # Build an Up API client from this item's token, or nil if unconfigured.
  def up_provider
    return nil unless credentials_configured?

    Provider::Up.new(access_token)
  end

  # The syncer responsible for importing and processing this item's data.
  def syncer
    UpItem::Syncer.new(self)
  end
end
