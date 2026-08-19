# frozen_string_literal: true

module RedbarkItem::Provided
  extend ActiveSupport::Concern

  def redbark_provider
    return nil unless credentials_configured?

    Provider::Redbark.new(
      api_key: api_key
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def redbark_credentials
    return nil unless credentials_configured?

    {
      api_key: api_key
    }
  end
end
