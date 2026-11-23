# frozen_string_literal: true

class EmailAlertConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(email_alert_item_id:, account_id:)
    Rails.logger.info(
      "EmailAlertConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    email_alert_item = EmailAlertItem.find_by(id: email_alert_item_id)
    return unless email_alert_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("EmailAlertConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "EmailAlertConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
