class EnableBankingSyncRetryJob < ApplicationJob
  queue_as :scheduled

  def perform(item, expected_retry_at)
    return if item.scheduled_for_deletion? || item.needs_authorization?
    return unless item.sync_retry_pending? && item.next_sync_at.iso8601(6) == expected_retry_at

    if item.sync_cooldown?
      self.class.set(wait_until: item.next_sync_at).perform_later(item, expected_retry_at)
      return
    end

    item.sync_later
  end
end
