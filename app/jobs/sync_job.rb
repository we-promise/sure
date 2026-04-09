class SyncJob < ApplicationJob
  queue_as :high_priority

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    # Attach a transient predicate for this execution only
    sync.balances_only = balances_only

    sync.perform
  end
end
