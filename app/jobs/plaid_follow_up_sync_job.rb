class PlaidFollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  def perform(plaid_item, active_sync_id:, attempts_remaining: MAX_ATTEMPTS)
    if plaid_item.syncs.incomplete.exists?(id: active_sync_id)
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(
          plaid_item,
          active_sync_id: active_sync_id,
          attempts_remaining: attempts_remaining - 1
        )
      else
        message = "Gave up waiting for PlaidItem #{plaid_item.id} sync #{active_sync_id} to finish"
        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: message,
          source: self.class.name,
          family: plaid_item.family,
          provider_key: "plaid",
          metadata: { plaid_item_id: plaid_item.id, active_sync_id: active_sync_id }
        )
      end

      return
    end

    plaid_item.sync_later
  end
end
