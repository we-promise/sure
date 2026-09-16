class SnaptradeFollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  def perform(snaptrade_item, attempts_remaining: MAX_ATTEMPTS)
    if snaptrade_item.syncs.visible.exists?
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(snaptrade_item, attempts_remaining: attempts_remaining - 1)
      else
        Rails.logger.warn("SnaptradeFollowUpSyncJob - gave up waiting for SnaptradeItem #{snaptrade_item.id} to finish syncing")
      end

      return
    end

    snaptrade_item.sync_later
  end
end
