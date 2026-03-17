# frozen_string_literal: true

module IndexaCapitalItem::Provided
  extend ActiveSupport::Concern

  def indexa_capital_provider
    return nil unless credentials_configured?

    token = resolved_api_token
    if token.present?
      Provider::IndexaCapital.new(api_token: token)
    else
      Provider::IndexaCapital.new(
        username: username,
        document: document,
        password: password
      )
    end
  end

  def indexa_capital_credentials
    return nil unless credentials_configured?

    { username: username, document: document, password: password }
  end

  def credentials_configured?
    resolved_api_token.present? || (username.present? && document.present? && password.present?)
  end

  private

    # Priority: stored token > env token
    def resolved_api_token
      api_token.presence || ENV["INDEXA_API_TOKEN"].presence
    end
end
