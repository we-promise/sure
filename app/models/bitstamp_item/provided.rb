# frozen_string_literal: true

module BitstampItem::Provided
  extend ActiveSupport::Concern

  def bitstamp_provider
    return nil unless credentials_configured?

    Provider::Bitstamp.new(
      api_key: api_key.to_s.strip,
      api_secret: api_secret.to_s.strip
    )
  end
end
