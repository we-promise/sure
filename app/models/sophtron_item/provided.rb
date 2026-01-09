module SophtronItem::Provided
  extend ActiveSupport::Concern

  def sophtron_provider
    return nil unless credentials_configured?

    Provider::Sophtron.new(user_id, access_key, base_url: effective_base_url)
  end
end
