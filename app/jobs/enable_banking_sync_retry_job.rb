class EnableBankingSyncRetryJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, lock_args: ->(args) { [ args.first, args.second ] }, on_conflict: :log

  def perform(item, _expected_retry_at)
    return if item.scheduled_for_deletion? || item.needs_authorization?
    return unless item.sync_retry_pending?

    expected_item_deadline, expected_scheduled_deadline = retry_deadlines(_expected_retry_at)
    return unless item.next_sync_at&.iso8601(6) == expected_item_deadline

    retry_at = item.sync_retry_at
    return unless retry_at

    if retry_at > Time.current || retry_at.iso8601(6) != expected_scheduled_deadline
      token = [ item.next_sync_at.iso8601(6), retry_at.iso8601(6) ].join("|")
      self.class.set(wait_until: retry_at).perform_later(item, token)
      return
    end

    item.sync_later
  end

  private

    def retry_deadlines(token)
      return [ token, token ] unless token.to_s.include?("|")

      token.to_s.split("|", 2)
    end
end
