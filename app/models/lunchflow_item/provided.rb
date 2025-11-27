module LunchflowItem::Provided
  extend ActiveSupport::Concern

  def lunchflow_provider
    return nil unless credentials_configured?

    Provider::Lunchflow.new(api_key, base_url: effective_base_url)
  end
end
