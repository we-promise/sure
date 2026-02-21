class SyncJob < ApplicationJob
  queue_as :high_priority

  # Retry on TwelveData rate limit errors with custom backoff
  # TwelveData has a per-minute rate limit, so we start with 70 seconds
  # to ensure the minute window has passed, then increase exponentially
  retry_on Provider::TwelveData::RateLimitError,
           wait: ->(executions) { [ 70 * (2 ** (executions - 1)), 600 ].min },
           attempts: 5

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
