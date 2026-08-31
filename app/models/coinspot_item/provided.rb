# frozen_string_literal: true

module CoinspotItem::Provided
  extend ActiveSupport::Concern

  def coinspot_provider
    return nil unless credentials_configured?

    Provider::Coinspot.new(
      api_key: api_key.to_s.strip,
      api_secret: api_secret.to_s.strip,
      nonce_generator: -> { next_nonce! }
    )
  end
end
