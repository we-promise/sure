class SyncJob < ApplicationJob
  queue_as :high_priority

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    # Attach a transient predicate for this execution only
    begin
      sync.define_singleton_method(:balances_only?) { balances_only }
    rescue => e
      Rails.logger.warn("SyncJob: failed to attach balances_only? flag: #{e.class} - #{e.message}")
    end

    sync.perform
  end
end
