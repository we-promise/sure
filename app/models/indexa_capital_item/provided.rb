# frozen_string_literal: true

module IndexaCapitalItem::Provided
  extend ActiveSupport::Concern

  def indexa_capital_provider
    return nil unless credentials_configured?

    Provider::IndexaCapital.new(
      username: username,
      document: document,
      password: password
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def indexa_capital_credentials
    return nil unless credentials_configured?

    {
      username: username,
      document: document,
      password: password
    }
  end
end
