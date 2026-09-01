class SyncAllJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting sync for all families")
    Family.find_each do |family|
      request_plaid_transactions_refreshes(family)
      family.sync_later
    rescue => e
      Rails.logger.error("Failed to sync family #{family.id}: #{e.message}")
    end
    Rails.logger.info("Completed sync for all families")
  end

  private

    def request_plaid_transactions_refreshes(family)
      family.plaid_items.syncable.find_each do |plaid_item|
        plaid_item.request_transactions_refresh_later
      rescue => error
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Scheduled Plaid transaction refresh could not be enqueued; continuing with normal sync",
          source: self.class.name,
          provider_key: "plaid",
          family: family,
          metadata: { error_class: error.class.name }
        )
      end
    end
end
