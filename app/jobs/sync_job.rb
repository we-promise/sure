class SyncJob < ApplicationJob
  queue_as :high_priority

  # How long to wait before checking again whether the running sync of the same syncable finished.
  WAIT_FOR_RUNNING_SYNC = 5.seconds

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    if sync.waiting_for_running_sync?
      self.class.set(wait: WAIT_FOR_RUNNING_SYNC).perform_later(sync, balances_only: balances_only)
      return
    end

    # Attach a transient predicate for this execution only
    begin
      sync.define_singleton_method(:balances_only?) { balances_only }
    rescue => e
      Rails.logger.warn("SyncJob: failed to attach balances_only? flag: #{e.class} - #{e.message}")
    end

    sync.perform
  end
end
