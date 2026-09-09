module MonobankItem::Provided
  extend ActiveSupport::Concern

  # Build a Monobank API client from this item's token, or nil if unconfigured.
  def monobank_provider
    return nil unless credentials_configured?

    Provider::Monobank.new(access_token)
  end

  # The syncer responsible for importing and processing this item's data.
  def syncer
    MonobankItem::Syncer.new(self)
  end
end
