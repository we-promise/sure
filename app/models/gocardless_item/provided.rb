# frozen_string_literal: true

module GocardlessItem::Provided
  extend ActiveSupport::Concern

  def gocardless_provider
    return nil unless credentials_configured?

    Provider::Gocardless.new(
      secret_id: secret_id,
      secret_key: secret_key
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def gocardless_credentials
    return nil unless credentials_configured?

    {
      secret_id: secret_id,
      secret_key: secret_key
    }
  end
end
