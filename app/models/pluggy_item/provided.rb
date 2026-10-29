# frozen_string_literal: true

module PluggyItem::Provided
  extend ActiveSupport::Concern

  # Returns credentials hash for API calls that need them passed explicitly
  def pluggy_credentials
    return nil unless credentials_configured?

    {
      client_id: client_id,
      client_secret: client_secret
    }
  end
end
