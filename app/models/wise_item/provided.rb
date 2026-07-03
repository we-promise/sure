# frozen_string_literal: true

module WiseItem::Provided
  extend ActiveSupport::Concern

  def wise_provider
    return nil unless credentials_configured?

    Provider::Wise.new(api_token: api_token)
  end

  def wise_credentials
    return nil unless credentials_configured?

    { api_token: api_token }
  end
end
