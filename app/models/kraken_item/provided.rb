# frozen_string_literal: true

module KrakenItem::Provided
  extend ActiveSupport::Concern

  def kraken_provider
    return nil unless credentials_configured?

    Provider::Kraken.new(
      api_key: api_key.to_s.strip,
      api_secret: api_secret.to_s.strip,
      nonce_generator: -> { next_nonce! }
    )
  end
end
