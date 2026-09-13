# frozen_string_literal: true

class PluggyConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(pluggy_item_id:, account_id:)
    Rails.logger.info(
      "PluggyConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    pluggy_item = PluggyItem.find_by(id: pluggy_item_id)
    return unless pluggy_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("PluggyConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "PluggyConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
