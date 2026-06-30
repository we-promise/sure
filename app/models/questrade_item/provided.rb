# frozen_string_literal: true

module QuestradeItem::Provided
  extend ActiveSupport::Concern

  def questrade_provider
    return nil unless credentials_configured?

    Provider::Questrade.new(
      refresh_token: refresh_token,
      api_server: api_server,
      # Questrade refresh tokens are single-use. Persist the rotated token +
      # api_server. This runs inside synchronize_exchange's row lock.
      on_token_refresh: ->(creds) {
        update!(refresh_token: creds[:refresh_token], api_server: creds[:api_server])
      },
      # Serialize the single-use token exchange across workers: take the row
      # lock, reload to get the freshest persisted token, and hand it to the
      # SDK to spend. Two concurrent syncs/jobs can no longer burn the same
      # token (the brief lock is held across the short token-exchange call).
      synchronize_exchange: ->(&blk) {
        with_lock do
          reload
          blk.call(refresh_token)
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
