module CoinstatsItem::Provided
  extend ActiveSupport::Concern

  def coinstats_provider
    return nil unless credentials_configured?

    Provider::Coinstats.new(api_key)
  end
end
