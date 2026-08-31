# frozen_string_literal: true

module CoinspotItem::Provided
  extend ActiveSupport::Concern

  # A Provider::Coinspot client authenticated with this connection's stored
  # credentials, or nil until both are configured. Wires the client's nonce
  # generator to the item's own monotonic counter so concurrent requests
  # never reuse a nonce.
  def coinspot_provider
    return nil unless credentials_configured?

    Provider::Coinspot.new(
      api_key: api_key.to_s.strip,
      api_secret: api_secret.to_s.strip,
      nonce_generator: -> { next_nonce! }
    )
  end
end
