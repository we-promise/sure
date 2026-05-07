class SophtronInitialLoadJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  def perform(sophtron_item, attempts_remaining: MAX_ATTEMPTS)
    if sophtron_item.syncing?
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(sophtron_item, attempts_remaining: attempts_remaining - 1)
      else
        Rails.logger.warn("SophtronInitialLoadJob - gave up waiting for SophtronItem #{sophtron_item.id} to finish syncing")
      end

      return
    end

    sophtron_item.sync_later
  end
end
