# Job for cleaning up SnapTrade brokerage connections asynchronously
#
# This job is enqueued after a SnaptradeAccount is destroyed to delete
# the connection from SnapTrade's API if no other accounts share it.
# Running this asynchronously avoids blocking the destroy transaction
# with an external API call.
#
class SnaptradeConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(snaptrade_item_id:, authorization_id:, account_id:)
    Rails.logger.info(
      "SnaptradeConnectionCleanupJob - Cleaning up connection #{authorization_id} " \
      "for former account #{account_id}"
    )

    snaptrade_item = SnaptradeItem.find_by(id: snaptrade_item_id)
    unless snaptrade_item
      Rails.logger.info(
        "SnaptradeConnectionCleanupJob - SnaptradeItem #{snaptrade_item_id} not found, " \
        "may have been deleted"
      )
      return
    end

    # Check if other accounts still use this authorization
    if snaptrade_item.snaptrade_accounts.where(snaptrade_authorization_id: authorization_id).exists?
      Rails.logger.info(
        "SnaptradeConnectionCleanupJob - Skipping deletion, other accounts share " \
        "authorization #{authorization_id}"
      )
      return
    end

    provider = snaptrade_item.snaptrade_provider
    credentials = snaptrade_item.snaptrade_credentials

    unless provider && credentials
      Rails.logger.warn(
        "SnaptradeConnectionCleanupJob - No provider/credentials for item #{snaptrade_item_id}"
      )
      return
    end

    Rails.logger.info(
      "SnaptradeConnectionCleanupJob - Deleting SnapTrade connection #{authorization_id}"
    )

    provider.delete_connection(
      user_id: credentials[:user_id],
      user_secret: credentials[:user_secret],
      authorization_id: authorization_id
    )

    Rails.logger.info(
      "SnaptradeConnectionCleanupJob - Successfully deleted connection #{authorization_id}"
    )
  rescue Provider::Snaptrade::ApiError => e
    # Connection may already be gone or credentials invalid - log but don't retry
    Rails.logger.warn(
      "SnaptradeConnectionCleanupJob - Failed to delete connection #{authorization_id}: " \
      "#{e.class} - #{e.message}"
    )
  rescue => e
    Rails.logger.error(
      "SnaptradeConnectionCleanupJob - Unexpected error deleting connection #{authorization_id}: " \
      "#{e.class} - #{e.message}"
    )
    Rails.logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
  end
end
