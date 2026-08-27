class PlaidTransactionsRefreshFollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  def perform(plaid_item, attempts_remaining: MAX_ATTEMPTS)
    if plaid_item.syncs.visible.exists?
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(plaid_item, attempts_remaining: attempts_remaining - 1)
      else
        Rails.logger.warn("PlaidTransactionsRefreshFollowUpSyncJob - gave up waiting for PlaidItem #{plaid_item.id} to finish syncing")
      end

      return
    end

    plaid_item.sync_later
  end
end
