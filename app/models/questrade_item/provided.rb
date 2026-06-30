# frozen_string_literal: true

module QuestradeItem::Provided
  extend ActiveSupport::Concern

  def questrade_provider
    return nil unless credentials_configured?

    Provider::Questrade.new(
      refresh_token: refresh_token,
      api_server: api_server,
      # Questrade refresh tokens are single-use: persist the rotated token (and
      # the api_server it hands back) immediately, under a row lock, so two
      # concurrent syncs can't burn the same token.
      on_token_refresh: ->(creds) {
        with_lock do
          update!(refresh_token: creds[:refresh_token], api_server: creds[:api_server])
        end
      }
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def questrade_credentials
    return nil unless credentials_configured?

    {
      refresh_token: refresh_token
    }
  end
end
