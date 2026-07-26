# frozen_string_literal: true

class RedbarkConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(redbark_item_id:, account_id:)
    Rails.logger.info(
      "RedbarkConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    redbark_item = RedbarkItem.find_by(id: redbark_item_id)
    return unless redbark_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("RedbarkConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "RedbarkConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
