# frozen_string_literal: true

module RevolutXItem::Provided
  extend ActiveSupport::Concern

  def revolut_x_provider
    return nil unless credentials_configured?

    Provider::RevolutX.new(api_key: api_key, private_key: signing_key)
  end
end
