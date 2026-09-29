class PlaidTransactionsRefreshFollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 36

  def perform(plaid_item, attempts_remaining: MAX_ATTEMPTS)
    if plaid_item.syncs.visible.exists?
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(plaid_item, attempts_remaining: attempts_remaining - 1)
      else
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Plaid transaction refresh follow-up exhausted its wait for an active sync",
          source: self.class.name,
          provider_key: "plaid",
          family: plaid_item.family
        )

        plaid_item.sync_later
      end

      return
    end

    plaid_item.sync_later
  end
end
