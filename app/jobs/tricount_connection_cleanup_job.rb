# frozen_string_literal: true

class TricountConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(tricount_item_id:, account_id:)
    Rails.logger.info(
      "TricountConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    tricount_item = TricountItem.find_by(id: tricount_item_id)
    return unless tricount_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("TricountConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "TricountConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
