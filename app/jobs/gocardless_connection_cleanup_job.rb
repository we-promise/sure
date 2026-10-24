# frozen_string_literal: true

class GocardlessConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(gocardless_item_id:, account_id:)
    Rails.logger.info(
      "GocardlessConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    gocardless_item = GocardlessItem.find_by(id: gocardless_item_id)
    return unless gocardless_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("GocardlessConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "GocardlessConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
